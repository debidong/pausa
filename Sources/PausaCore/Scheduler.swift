import Foundation

// Pure break scheduler. No timers, no UI, no wall clock: the caller feeds it
// monotonic time (seconds, including sleep) and current signals. Everything
// that can go wrong with timing lives here, so it is all unit-testable.

public enum BreakKind: String, Codable, Equatable, Sendable { case short, long }

public enum PauseReason: Hashable, Comparable, Sendable {
  // order = display priority
  case meeting, screenSharing   // "holds": person still at the screen, never interrupted on screen
  case micInUse                 // hold: mic alone, no camera / meeting app (2-hour recheck applies)
  case video                    // hold, but bounded by the deferral budget and the hard line
  case fullscreen
  case outsideHours          // outside the user's Pausa 时段 (lowest priority)
}

/// A soft reason to push a due break back a little (design §0 R1). Sources only say what they
/// are and how long they may defer one break; the scheduler owns all timing (one shared budget).
public enum DeferralKind: Hashable, Sendable {
  case typing, focusApp, focusMode
  case microphone   // mic on, not yet long enough to count as a meeting
  /// Firm: holds even past the shared budget and the hard line, for at most its own cap. Only
  /// the mic, so a call's first minute never gets a break on screen.
  var firm: Bool { self == .microphone }
}

public struct Deferral: Hashable, Sendable {
  public var kind: DeferralKind
  public var cap: Double                 // per-break cap for this source, seconds
  public var kinds: Set<BreakKind>       // which breaks it may defer (focus mode short-only by default)
  public init(_ kind: DeferralKind, cap: Double, kinds: Set<BreakKind> = [.short, .long]) {
    self.kind = kind; self.cap = cap; self.kinds = kinds
  }
  public static let typing = Deferral(.typing, cap: 30)
  /// Mic on but not yet a meeting: a due break waits for the dictation burst to end, at most this
  /// long; the detector counts the mic alone as a meeting after the same time (micMinRun).
  public static let microphone = Deferral(.microphone, cap: 60)
  public static func focusApp() -> Deferral { Deferral(.focusApp, cap: 15 * 60) }
  public static func focusMode(shortOnly: Bool) -> Deferral {
    Deferral(.focusMode, cap: 15 * 60, kinds: shortOnly ? [.short] : [.short, .long])
  }
}

public enum AwayKind: String, Codable, Equatable, Sendable {
  case locked   // lid-close, sleep, screen lock
  case idle     // sustained zero input without screen engagement
}

public enum BreakOutcome: Sendable { case completed, skipped, snoozed }

public struct Config: Equatable, Sendable {
  /// One break interval; every `longEveryNth` break is a long one (that break counts as the Nth).
  public var breakEvery: Double = 20 * 60
  public var longEveryNth: Int = 3
  public var shortLength: Double = 20
  public var longLength: Double = 5 * 60
  public var warnLead: Double = 30          // heads-up before a break
  public var typingGrace: Double = 30       // max wait for user to stop typing
  public var typingIdle: Double = 2         // input gap that counts as "stopped"
  public var snoozeLength: Double = 5 * 60
  public var maxSnoozes = 2
  // Idle & natural break thresholds (decoupled from longLength).
  public var idleFreezeThreshold: Double = 5 * 60      // 5 min unengaged idle freezes & rolls back
  public var idleNaturalLongReset: Double = 10 * 60    // 10 min unengaged idle resets full cycle
  public var idleHardLineReset: Double = 15 * 60       // 15 min unengaged idle required past hard line
  public var returnCushion: Double = 90                // minimum breathing room on sub-reset return
  public var urgentPauseDuration: Double = 30 * 60     // auto-recovery ceiling for urgent pause
  // After a meeting (see Scheduler.meetingEnded).
  public var meetingLongMin: Double = 30 * 60   // a meeting this long earns a long break
  public var meetingNearLong: Double = 5 * 60   // or the long break was this close (or overdue)
  public var afterMeetingDelay: Double = 3 * 60 // long break due this long after the meeting ends
  // Unified deferral budget (design §0).
  public var longDeferBudget: Double = 30 * 60
  public var shortDeferBudget: Double = 10 * 60
  public var hardLine: Double = Double(Config.defaultHardLineMinutes * 60)   // since last completed long break
  /// The hard line (「长休息最晚间隔」), in minutes: the setting's options and its default. Settings
  /// passes the chosen value to hardLine and to the caps below; nothing else may hard-code it.
  public static let hardLineOptions = [60, 90, 120]
  public static let defaultHardLineMinutes = 90
  /// A stored value that is not one of the options counts as the default.
  public static func hardLineMinutes(_ stored: Int) -> Int { hardLineOptions.contains(stored) ? stored : defaultHardLineMinutes }
  public init() {}

  /// Shared deferral budget and length of each kind of break.
  func deferBudget(_ kind: BreakKind) -> Double { kind == .long ? longDeferBudget : shortDeferBudget }
  func length(_ kind: BreakKind) -> Double { kind == .long ? longLength : shortLength }

  /// Old name, kept for callers that still say "short".
  public var shortEvery: Double { get { breakEvery } set { breakEvery = newValue } }

  /// interval × N may not exceed the hard line of `line` minutes (settings grey out the rest).
  public static func allows(everyMin: Int, nth: Int, line: Int) -> Bool { nth >= 1 && everyMin * nth <= line }

  /// Settings show "短休息 [count] 次后进行一次长休息": count = short breaks between long ones = N − 1.
  public static func count(fromNth n: Int) -> Int { max(1, n - 1) }
  public static func nth(fromCount c: Int) -> Int { max(1, c) + 1 }
  /// The same cap in count terms: interval × (count + 1) ≤ line (same Config.allows).
  public static func allows(everyMin: Int, count: Int, line: Int) -> Bool { allows(everyMin: everyMin, nth: nth(fromCount: count), line: line) }

  /// Migrate the old "long break every M minutes" to the nearest N for interval `everyMin`.
  public static func nth(forLegacyLongEveryMin m: Int, everyMin: Int, line: Int) -> Int {
    guard everyMin > 0 else { return 3 }
    let maxN = max(2, line / everyMin)
    let n = Int((Double(m) / Double(everyMin)).rounded())
    return min(maxN, max(2, n))
  }
}

/// Sub-state while a break is due (`remaining <= 0`) and held back by a soft deferral or typing grace.
public enum DeferralSubstate: Equatable, Sendable {
  case source(DeferralKind)
  case typingGrace(since: Double)

  /// True when the cursor pill should show the "waiting for typing to pause" prompt.
  public var showsTypingPill: Bool {
    switch self {
    case .source(.typing), .source(.microphone), .typingGrace: return true
    case .source(.focusApp), .source(.focusMode): return false
    }
  }
}

public enum Phase: Equatable, Sendable {
  case working
  case warning(BreakKind, cardOpened: Bool)        // heads-up shown, break imminent
  case deferred(BreakKind, DeferralSubstate)       // due (remaining <= 0), waiting on deferral or typing pause
  case onBreak(BreakKind, endsAt: Double, planned: Double)
  case paused(PauseReason)                         // highest-priority reason
}

public enum Command: Equatable {
  case showWarning(BreakKind, secondsLeft: Double)
  case startBreak(BreakKind, length: Double)
  case resumeBreak(BreakKind, remaining: Double)   // back from a lock mid-break: show the rest
  case recorded(BreakKind, planned: Double, BreakResult)   // a break ended for good: one stats row
  case endBreak
}

public struct Scheduler {
  /// Physical session presence: locking, sleeping, or sustained idle freezes work accumulation.
  public enum Presence: Equatable, Sendable {
    case active
    case away(kind: AwayKind, since: Double)
    case awaitingReturn(breakKind: BreakKind, breakStartedAt: Double, breakEndedAt: Double)
  }

  /// User-initiated reminder pause ("暂停提醒" / "紧急暂停提醒"), with optional auto-expiry wall clock.
  public enum ManualPauseState: Equatable, Sendable {
    case none
    case paused(sinceWall: Double, untilWall: Double? = nil)
  }

  /// Single derived top-level operating mode with priority defined in one place.
  public enum EffectiveMode: Equatable, Sendable {
    case manualPaused(sinceWall: Double, isAway: Bool)
    case away(since: Double)
    case onBreak(BreakKind, endsAt: Double, planned: Double)
    case autoPaused(PauseReason)
    case warning(BreakKind, cardOpened: Bool)
    case deferred(BreakKind, DeferralSubstate)
    case working
  }

  public var config: Config
  public private(set) var phase: Phase = .working
  public private(set) var presence: Presence = .active
  public private(set) var manualPause: ManualPauseState = .none

  // Active work time since the last break (any kind), and breaks since the last long one.
  private(set) var sinceBreak: Double = 0
  private(set) var breaksSinceLong = 0
  public private(set) var consecutiveSkips = 0
  private var consecutiveShortSkips = 0
  private var lastShortSkipped = false
  private var breakStartedAt: Double?
  private var countedIdleBreak: Double = 0
  private var countedIdleLong: Double = 0
  private var unengagedIdle: Double = 0
  private var lastTick: Double?
  private var snoozes = 0
  private var holdStartedAt: Double?             // any hold (meeting / screen share / video) started
  private var sinceLongDone: Double = 0          // active time since last *completed* long break
  private var deferUsed: Double = 0              // shared budget used for the current due break
  private var deferBySource: [DeferralKind: Double] = [:]
  static let holds: Set<PauseReason> = [.meeting, .micInUse, .screenSharing, .video, .fullscreen]
  static let boundedHolds: Set<PauseReason> = [.video, .fullscreen]

  public init(config: Config = Config()) { self.config = config }

  /// Progressive Space / pointer hold-to-skip duration: 2.0s → 3.5s → 5.0s → 6.5s → 8.0s max.
  public static func holdDuration(forConsecutiveSkips k: Int) -> Double {
    min(8.0, 2.0 + 1.5 * Double(max(0, k)))
  }

  public var skipHoldDuration: Double { Self.holdDuration(forConsecutiveSkips: consecutiveSkips) }

  public var isAway: Bool {
    switch presence {
    case .away, .awaitingReturn: return true
    case .active: return false
    }
  }

  /// True only during explicit OS lock / display sleep / system sleep (where detector suspends polling).
  public var isLockedAway: Bool {
    if case .away(kind: .locked, _) = presence { return true }
    return false
  }

  public var isManuallyPaused: Bool {
    if case .paused = manualPause { return true }
    return false
  }

  /// Active soft/firm deferral source for the menu bar, derived directly from `phase`.
  public var deferring: DeferralKind? {
    if case .deferred(_, .source(let kind)) = phase { return kind }
    return nil
  }

  /// Authoritative top-level mode combining `manualPause`, `presence`, and `phase`.
  public var effectiveMode: EffectiveMode {
    if case .paused(let sinceWall, _) = manualPause {
      return .manualPaused(sinceWall: sinceWall, isAway: isAway)
    }
    switch presence {
    case .away(_, let since):
      return .away(since: since)
    case .awaitingReturn(_, _, let endedAt):
      return .away(since: endedAt)
    case .active:
      break
    }
    switch phase {
    case .onBreak(let k, let endsAt, let planned): return .onBreak(k, endsAt: endsAt, planned: planned)
    case .paused(let r):                           return .autoPaused(r)
    case .warning(let k, let opened):              return .warning(k, cardOpened: opened)
    case .deferred(let k, let sub):                return .deferred(k, sub)
    case .working:                                 return .working
    }
  }

  /// Seconds until the next break and which one, for the menu bar.
  public var next: (kind: BreakKind, remaining: Double, fraction: Double) {
    let remaining = max(0, config.breakEvery - sinceBreak)
    return (isLong(afterBreaks: 0, at: remaining) ? .long : .short, remaining, min(1, max(0, sinceBreak) / config.breakEvery))
  }

  /// A long break is owed until one is completed (Steve, 2026-10-20). Two ways it comes due:
  /// the Nth break of the cycle, or interval × N of active time since the last *completed* long
  /// break (default 60 min). Skips don't reset either, so a skipped long break comes back as the
  /// next break, and nothing slips past the hard line (interval × N <= hardLine, Config.allows).
  /// The cycle count stays because meetingEnded uses it to owe a long break early.
  /// `k` breaks from now, `left` seconds of work away.
  private func isLong(afterBreaks k: Int, at left: Double) -> Bool {
    let n = max(1, config.longEveryNth)
    return breaksSinceLong + 1 + k >= n || sinceLongDone + left >= config.breakEvery * Double(n)
  }

  /// Which break in the cycle comes next, 1-based (「第 2 次 / 共 3 次」).
  public var cycle: (index: Int, of: Int) {
    let n = max(1, config.longEveryNth)
    return (next.kind == .long ? n : min(breaksSinceLong + 1, n), n)
  }

  /// Seconds until each kind of break is due, for the menu's two countdown rows.
  public var remaining: (short: Double, long: Double) {
    let r = next.remaining
    var k = 0
    while !isLong(afterBreaks: k, at: r + Double(k) * config.breakEvery) { k += 1 }
    return (next.kind == .short ? r : r + config.breakEvery, r + Double(k) * config.breakEvery)
  }

  /// Seconds the current due break may still be deferred (shared budget), for 「还可推迟 12 分钟」.
  public var deferralLeft: Double {
    let kind = next.kind
    if mustNotDefer(kind) { return 0 }
    return max(0, config.deferBudget(kind) - deferUsed)
  }

  /// Seconds `kind` may still defer the due break: its own cap and the shared budget, whichever is less.
  public func deferralLeft(for kind: DeferralKind, cap: Double) -> Double {
    let own = max(0, cap - (deferBySource[kind] ?? 0))
    return kind.firm ? own : min(deferralLeft, own)
  }

  /// Hard line reached: the long break may not wait.
  private func mustNotDefer(_ kind: BreakKind) -> Bool {
    kind == .long && sinceLongDone >= config.hardLine
  }

  /// Whether the 5-minute snooze button on a running break is allowed right now.
  public var canSnoozeOnBreak: Bool {
    guard snoozes < config.maxSnoozes else { return false }
    if case .onBreak(.long, _, _) = phase {
      if mustNotDefer(.long) { return false }
      if sinceLongDone > 0 && sinceLongDone + config.snoozeLength > config.hardLine { return false }
    }
    return true
  }

  /// Call about once a second.
  public mutating func tick(now: Double, reasons: Set<PauseReason>, inputIdle: Double) -> [Command] {
    tick(now: now, reasons: reasons, deferrals: [], inputIdle: inputIdle, screenEngaged: false, wallNow: nil)
  }

  public mutating func tick(now: Double, reasons inReasons: Set<PauseReason>, deferrals: [Deferral],
                            inputIdle: Double, screenEngaged: Bool = false, wallNow: Double? = nil) -> [Command] {
    if case .away(kind: .locked, _) = presence { return [] }

    // Auto-expire bounded manual/urgent pauses once their wall-clock deadline passes.
    if case .paused(_, let untilWall?) = manualPause, let wallNow, wallNow >= untilWall {
      let resumeCmds = resumeManually(now: now)
      if !resumeCmds.isEmpty { return resumeCmds }
    }

    let engaged = screenEngaged || !inReasons.isDisjoint(with: Self.holds)

    switch presence {
    case .away(kind: .locked, _):
      return []
    case .away(kind: .idle, _):
      guard inputIdle < config.typingIdle || engaged else { return [] }
      _ = exitAway(.idle, now: now)
    case .awaitingReturn(let bKind, let bStartedAt, _):
      guard inputIdle < config.typingIdle || engaged else {
        lastTick = now
        return []
      }
      if bKind == .short, now - bStartedAt >= config.longLength {
        breaksSinceLong = 0
        sinceLongDone = 0
        countedIdleLong = 0
        clearDeferral()
        consecutiveSkips = 0
        consecutiveShortSkips = 0
        lastShortSkipped = false
      }
      unengagedIdle = 0
      countedIdleBreak = 0
      countedIdleLong = 0
      presence = .active
      lastTick = now
    case .active:
      break
    }

    if case .paused = manualPause {
      let hadPrevTick = lastTick != nil
      let dt = lastTick.map { max(0, now - $0) } ?? 0
      let idleNow = max(0, inputIdle)
      if engaged || inReasons.contains(.outsideHours) {
        unengagedIdle = 0
        countedIdleBreak = 0
        countedIdleLong = 0
      } else {
        let nextUnengaged = hadPrevTick ? min(unengagedIdle + dt, idleNow) : idleNow
        if nextUnengaged >= config.idleFreezeThreshold {
          sinceLongDone = max(0, sinceLongDone - countedIdleLong)
          unengagedIdle = 0
          countedIdleBreak = 0
          countedIdleLong = 0
          presence = .away(kind: .idle, since: now - nextUnengaged)
          lastTick = now
          return []
        }
        unengagedIdle = nextUnengaged
      }
      lastTick = now
      if case .onBreak = phase { return [] }
      if !inReasons.contains(.outsideHours) {
        sinceLongDone += dt
        if engaged {
          countedIdleLong = 0
        } else {
          countedIdleLong = min(countedIdleLong + dt, idleNow)
        }
      }
      return []
    }

    let hadPrevTick = lastTick != nil
    let dt = lastTick.map { max(0, now - $0) } ?? 0
    lastTick = now
    var reasons = inReasons

    if case .onBreak(let bKind, let endsAt, let planned) = phase {
      if now >= endsAt {
        let bStart = breakStartedAt ?? (endsAt - planned)
        let cmds = finish(.completed, now: now)
        if !engaged && inputIdle >= max(planned, 60) {
          presence = .awaitingReturn(breakKind: bKind, breakStartedAt: bStart, breakEndedAt: now)
        }
        return cmds
      }
      return []
    }

    // Meetings: the person is still sitting at the screen, so meeting time counts toward the
    // long break ("get up") but not the short one (eyes are on faces/slides, and a 20 s break
    // can't happen mid-call anyway).
    let due = next.remaining <= 0
    if !reasons.isDisjoint(with: Self.holds) {
      unengagedIdle = 0
      countedIdleBreak = 0
      countedIdleLong = 0
      if next.kind == .long { sinceBreak += dt }   // sitting counts toward "get up", not toward eyes
      sinceLongDone += dt
      // A break held by a hold eats the shared budget (wall clock, once, however many sources).
      if due { deferUsed += dt }
      let kind = next.kind
      let budget = config.deferBudget(kind)
      // Video and fullscreen are bounded: past the budget or the hard line it stops holding. Meetings and
      // screen sharing keep waiting (no overlay on someone else's screen); the break follows after.
      if due && !reasons.isDisjoint(with: Self.boundedHolds) && (deferUsed >= budget || mustNotDefer(kind)) {
        reasons.subtract(Self.boundedHolds)
        if reasons.isDisjoint(with: Self.holds) { holdStartedAt = nil }   // forced, not "ended": no make-up
      }
    }
    if !reasons.isDisjoint(with: Self.holds) {
      if holdStartedAt == nil { holdStartedAt = now }
    } else if let start = holdStartedAt {
      holdStartedAt = nil
      meetingEnded(lasted: now - start)
    }

    if let top = reasons.min() {
      unengagedIdle = 0
      countedIdleBreak = 0
      countedIdleLong = 0
      phase = .paused(top)
      return []
    }
    if case .paused = phase { phase = .working }

    // Unengaged zero-input at >= idleFreezeThreshold (5 min): roll back the unconfirmed tail and freeze.
    let idleNow = max(0, inputIdle)
    if engaged {
      unengagedIdle = 0
    } else {
      let nextUnengaged = hadPrevTick ? min(unengagedIdle + dt, idleNow) : idleNow
      if nextUnengaged >= config.idleFreezeThreshold {
        sinceBreak = max(0, sinceBreak - countedIdleBreak)
        sinceLongDone = max(0, sinceLongDone - countedIdleLong)
        unengagedIdle = 0
        countedIdleBreak = 0
        countedIdleLong = 0
        clearTransientPhase()
        presence = .away(kind: .idle, since: now - nextUnengaged)
        return []
      }
      unengagedIdle = nextUnengaged
    }

    sinceBreak += dt
    sinceLongDone += dt
    if engaged {
      countedIdleBreak = 0
      countedIdleLong = 0
    } else {
      countedIdleBreak = min(countedIdleBreak + dt, idleNow)
      countedIdleLong = min(countedIdleLong + dt, idleNow)
    }

    let (kind, remaining, _) = next
    if remaining > config.warnLead { phase = .working; return [] }
    if remaining > 0 {
      let opensNow = Int(remaining.rounded(.up)) >= PreBreakState.minOpenSeconds
      if case .warning(let prevKind, let wasOpen) = phase, prevKind == kind {
        if opensNow && !wasOpen { phase = .warning(kind, cardOpened: true) }
        return []
      }
      phase = .warning(kind, cardOpened: opensNow)
      return [.showWarning(kind, secondsLeft: remaining)]
    }

    // Due. Soft deferrals share one budget; each is also limited by its own cap.
    let budget = config.deferBudget(kind)
    let hard = mustNotDefer(kind)
    let usable = deferrals.filter { d in
      d.kinds.contains(kind) && (deferBySource[d.kind] ?? 0) < d.cap
        // R20: past the hard line nothing defers the long break, not even typing. A firm
        // deferral (the mic, at most a minute) waits to learn whether it is a meeting.
        && (d.kind.firm || (!hard && deferUsed < budget))
    }
    if !usable.isEmpty {
      deferUsed += dt
      for d in usable { deferBySource[d.kind, default: 0] += dt }
      let chosen: DeferralKind = usable.contains { $0.kind == .typing } ? .typing : usable[0].kind
      phase = .deferred(kind, .source(chosen))
      return []
    }

    // Wait for a pause in typing, but not forever (R19, R21): the wait comes out of the shared
    // budget, and stops when the budget is spent or the hard line is reached.
    let since: Double
    if case .deferred(let prevKind, .typingGrace(let prevSince)) = phase, prevKind == kind {
      since = prevSince
    } else {
      since = now
    }
    if !hard && deferUsed < budget && inputIdle < config.typingIdle && now - since < config.typingGrace {
      deferUsed += dt
      phase = .deferred(kind, .typingGrace(since: since))
      return []
    }
    return startBreak(kind, now: now)
  }

  private mutating func startBreak(_ kind: BreakKind, now: Double) -> [Command] {
    let length = config.length(kind)
    breakStartedAt = now
    unengagedIdle = 0
    countedIdleBreak = 0
    countedIdleLong = 0
    phase = .onBreak(kind, endsAt: now + length, planned: length)
    return [.startBreak(kind, length: length)]
  }

  private mutating func clearDeferral() { deferUsed = 0; deferBySource = [:] }

  /// User skipped, snoozed, or the overlay finished.
  public mutating func finish(_ outcome: BreakOutcome, now: Double) -> [Command] {
    guard case .onBreak(let kind, let endsAt, let planned) = phase else { return [] }
    // Past the hard line the long break can't be skipped or snoozed, whatever the UI shows.
    if kind == .long && outcome != .completed && mustNotDefer(.long) { return [] }
    // A 5-minute snooze on a long break may never cross the hard line (blocks 88m -> 93m bypass).
    if outcome == .snoozed && kind == .long && snoozes < config.maxSnoozes
        && sinceLongDone > 0 && sinceLongDone + config.snoozeLength > config.hardLine {
      return []
    }

    let started = breakStartedAt ?? (endsAt - planned)
    let actual = max(0, min(planned, now - started))
    let rho = planned > 0 ? actual / planned : 0
    breakStartedAt = nil
    phase = .working

    // Resting >= 80% of the break settles as completed rather than a full-penalty skip.
    let effectiveOutcome: BreakOutcome = (outcome == .skipped && rho >= 0.80) ? .completed : outcome

    // A snooze inside the limit is not a result yet: the same break comes back and ends once.
    // Past the limit it is reset like a skip, so it counts as one.
    var result: BreakResult?
    switch effectiveOutcome {
    case .completed:
      result = .completed
      clearDeferral()
      if kind == .long { sinceLongDone = 0; countedIdleLong = 0 }
      consecutiveSkips = 0
      consecutiveShortSkips = 0
      lastShortSkipped = false
      reset(kind, done: true)
    case .skipped:
      result = .skipped
      if kind == .short {
        clearDeferral()
      } else if rho >= 0.25 {
        // Partial rest credit (25%..<80% of a long break): proportionally roll back sitting time.
        sinceLongDone = max(0, sinceLongDone * (1.0 - 0.8 * rho))
      }
      consecutiveSkips += 1
      reset(kind, done: false)   // a skipped long break is still owed: it comes back next
      if kind == .short {
        consecutiveShortSkips += 1
        lastShortSkipped = true
        if consecutiveShortSkips >= 2 {
          breaksSinceLong += 1
        }
      } else if sinceLongDone > 0 {
        // Horizon clamping: a skipped long break comes back no later than the hard line.
        let rNext = min(config.breakEvery, max(0, config.hardLine - sinceLongDone))
        sinceBreak = config.breakEvery - rNext
      }
    case .snoozed where snoozes < config.maxSnoozes:
      snoozes += 1
      let back = config.snoozeLength
      sinceBreak = config.breakEvery - back   // same break comes back; deferUsed & cycle count preserved
      countedIdleBreak = 0
    case .snoozed:
      result = .skipped
      if kind == .short { clearDeferral() }
      consecutiveSkips += 1
      reset(kind, done: false)
      if kind == .long && sinceLongDone > 0 {
        let rNext = min(config.breakEvery, max(0, config.hardLine - sinceLongDone))
        sinceBreak = config.breakEvery - rNext
      }
    }
    return (result.map { [.recorded(kind, planned: planned, $0)] } ?? []) + [.endBreak]
  }

  /// Screen locked or Mac going to sleep: freeze all work/hard-line accumulation until `exitAway`.
  public mutating func enterAway(now: Double) {
    switch presence {
    case .away(kind: .locked, _):
      return
    case .away(kind: .idle, let since):
      // Preserve the earlier start of idle absence when display sleep / screen lock follows.
      presence = .away(kind: .locked, since: since)
      lastTick = now
    case .awaitingReturn(_, let bStart, _):
      presence = .away(kind: .locked, since: bStart)
      lastTick = now
    case .active:
      presence = .away(kind: .locked, since: now)
      lastTick = now
    }
  }

  /// Screen unlocked, Mac woke up, or input resumed after idle: settle break/reset credit for the away span.
  @discardableResult
  public mutating func exitAway(_ kind: AwayKind, now: Double) -> [Command] {
    let secs: Double
    switch presence {
    case .away(_, let since):
      secs = max(0, now - since)
    case .awaitingReturn(_, let bStart, _):
      secs = max(0, now - bStart)
    case .active:
      secs = 0
    }
    presence = .active
    return away(kind, seconds: secs, now: now)
  }

  /// The machine or user was away (`locked` or unengaged `idle`) for `seconds`.
  /// Call on return; time spent away is never counted as work.
  @discardableResult
  public mutating func away(_ kind: AwayKind, seconds: Double, now: Double) -> [Command] {
    lastTick = now
    unengagedIdle = 0
    countedIdleBreak = 0
    countedIdleLong = 0
    if case .onBreak(let k, let endsAt, _) = phase {
      if now >= endsAt { return finish(.completed, now: now) }
      return [.resumeBreak(k, remaining: endsAt - now)]
    }
    let longThreshold: Double = switch kind {
    case .locked:
      config.longLength
    case .idle:
      mustNotDefer(.long) ? max(config.idleHardLineReset, config.longLength * 2)
                          : max(config.idleNaturalLongReset, config.longLength * 2)
    }
    if seconds >= longThreshold {
      reset(.long, done: true)
      sinceLongDone = 0
      clearDeferral()
      consecutiveSkips = 0
      consecutiveShortSkips = 0
      lastShortSkipped = false
      clearTransientPhase()
    } else if kind == .locked && seconds >= config.shortLength {
      if next.kind == .short {
        snoozes = 0
        sinceBreak = 0   // eyes rested for a short break; never resets an upcoming long break
        lastShortSkipped = false
        clearTransientPhase()
      } else if !mustNotDefer(.long) {
        applyReturnCushion()
      }
    } else if kind == .idle && seconds >= config.idleFreezeThreshold && !mustNotDefer(.long) {
      applyReturnCushion()
    }
    return []
  }

  private mutating func applyReturnCushion() {
    let cushion = min(config.returnCushion, config.breakEvery)
    if config.breakEvery - sinceBreak < cushion {
      sinceBreak = config.breakEvery - cushion
    }
    clearTransientPhase()
  }

  private mutating func clearTransientPhase() {
    switch phase {
    case .warning, .deferred: phase = .working
    case .working, .onBreak, .paused: break
    }
  }

  /// 「紧急暂停提醒」 (spec-hardline §5.2): the one way out of a long break past the hard line,
  /// where `finish` refuses skip and snooze. Ends the long break on screen, or the one the pre-break
  /// panel announces at the line, as skipped: one stats row, the long break stays owed and nothing
  /// is reset that a skip keeps (sinceLongDone runs on). When `wallNow` is supplied, enters a bounded
  /// 30-minute `manualPause` so reminders auto-recover.
  public mutating func urgentPause(now: Double, wallNow: Double? = nil) -> [Command] {
    let cmds: [Command]
    switch phase {
    case .onBreak(.long, _, let planned) where mustNotDefer(.long):
      cmds = [.recorded(.long, planned: planned, .skipped), .endBreak]
    case .warning(.long, _) where atHardLine, .deferred(.long, _) where atHardLine:
      cmds = [.recorded(.long, planned: config.longLength, .skipped)]
    default:
      if let wallNow {
        manualPause = .paused(sinceWall: wallNow, untilWall: wallNow + config.urgentPauseDuration)
        lastTick = now
      }
      return []
    }
    breakStartedAt = nil
    phase = .working
    consecutiveSkips += 1
    reset(.long, done: false)
    if let wallNow {
      manualPause = .paused(sinceWall: wallNow, untilWall: wallNow + config.urgentPauseDuration)
      lastTick = now
    }
    return cmds
  }

  /// Menu 「暂停提醒」: settles any break on screen (normal skip, or urgent skip at the hard line)
  /// and transitions into `manualPause` (auto-expiring at `untilWall`, e.g. end of day).
  public mutating func pauseManually(wallNow: Double, untilWall: Double? = nil, now: Double) -> [Command] {
    var cmds: [Command] = []
    if case .onBreak = phase {
      cmds = finish(.skipped, now: now)
      if cmds.isEmpty { cmds = urgentPause(now: now) }
    } else {
      clearTransientPhase()
    }
    manualPause = .paused(sinceWall: wallNow, untilWall: untilWall)
    lastTick = now
    return cmds
  }

  /// Menu 「恢复提醒」: clears `manualPause` and enforces the hard line if reached while paused.
  public mutating func resumeManually(now: Double) -> [Command] {
    manualPause = .none
    return manualPauseEnded(now: now)
  }

  /// 暂停提醒: no reminders while active, but sitting time since the last long break keeps counting.
  public mutating func manualPauseTick(now: Double, wallNow: Double? = nil) {
    if let wallNow, case .paused(_, let untilWall?) = manualPause, wallNow >= untilWall {
      manualPause = .none
      _ = manualPauseEnded(now: now)
      return
    }
    if isAway { return }
    let dt = lastTick.map { max(0, now - $0) } ?? 0
    lastTick = now
    if case .onBreak = phase { return }
    sinceLongDone += dt
  }

  /// The manual pause ended (恢复提醒). Past the hard line the long break starts now
  /// and can't be deferred (mustNotDefer); otherwise counting simply resumes.
  public mutating func manualPauseEnded(now: Double) -> [Command] {
    lastTick = now
    unengagedIdle = 0
    countedIdleBreak = 0
    countedIdleLong = 0
    if case .onBreak = phase { return [] }
    guard sinceLongDone >= config.hardLine else { return [] }
    return startBreak(.long, now: now)
  }

  /// What survives a quit / relaunch (design: persistence). Wall clock, not monotonic: the
  /// monotonic clock restarts with the process, so the gap is measured with `Date`.
  public struct Saved: Codable, Equatable, Sendable {
    public var sinceLongDone: Double
    public var deferUsed: Double
    public var sinceBreak: Double
    public var breaksSinceLong: Int
    public var savedAt: Double              // wall clock, seconds since 1970
    public var manualPausedSince: Double?   // wall clock when manually paused, nil otherwise
    public var manualPauseUntil: Double?    // optional wall-clock auto-expiry
    public var consecutiveSkips: Int?
    public var consecutiveShortSkips: Int?
    public var lastShortSkipped: Bool?

    public init(sinceLongDone: Double, deferUsed: Double, sinceBreak: Double,
                breaksSinceLong: Int, savedAt: Double, manualPausedSince: Double? = nil,
                manualPauseUntil: Double? = nil, consecutiveSkips: Int? = nil,
                consecutiveShortSkips: Int? = nil, lastShortSkipped: Bool? = nil) {
      self.sinceLongDone = sinceLongDone
      self.deferUsed = deferUsed
      self.sinceBreak = sinceBreak
      self.breaksSinceLong = breaksSinceLong
      self.savedAt = savedAt
      self.manualPausedSince = manualPausedSince
      self.manualPauseUntil = manualPauseUntil
      self.consecutiveSkips = consecutiveSkips
      self.consecutiveShortSkips = consecutiveShortSkips
      self.lastShortSkipped = lastShortSkipped
    }
  }

  /// Snapshot for UserDefaults. A running break is saved as not taken (it never completed).
  public func saved(wallClock: Double) -> Saved {
    let mpSince: Double?
    let mpUntil: Double?
    if case .paused(let sinceWall, let untilWall) = manualPause {
      mpSince = sinceWall
      mpUntil = untilWall
    } else {
      mpSince = nil
      mpUntil = nil
    }
    return Saved(sinceLongDone: sinceLongDone, deferUsed: deferUsed,
                 sinceBreak: sinceBreak, breaksSinceLong: breaksSinceLong,
                 savedAt: wallClock, manualPausedSince: mpSince,
                 manualPauseUntil: mpUntil,
                 consecutiveSkips: consecutiveSkips > 0 ? consecutiveSkips : nil,
                 consecutiveShortSkips: consecutiveShortSkips > 0 ? consecutiveShortSkips : nil,
                 lastShortSkipped: lastShortSkipped ? true : nil)
  }

  /// At launch: pick up where the last run stopped. The time the app was not running is treated
  /// like a locked screen: at least `longLength` of it counts as a long break taken (both the
  /// long-break clock and the defer budget reset); shorter gaps leave the counters as they were,
  /// so the hard line (mustNotDefer) survives a restart. A wall clock that moved backwards
  /// counts as no gap.
  public mutating func restore(_ s: Saved, wallClock: Double, now: Double) {
    sinceLongDone = max(0, s.sinceLongDone)
    deferUsed = max(0, s.deferUsed)
    deferBySource = [:]
    sinceBreak = s.sinceBreak
    breaksSinceLong = max(0, s.breaksSinceLong)
    consecutiveSkips = max(0, s.consecutiveSkips ?? 0)
    consecutiveShortSkips = max(0, s.consecutiveShortSkips ?? 0)
    lastShortSkipped = s.lastShortSkipped ?? false
    breakStartedAt = nil
    unengagedIdle = 0
    countedIdleBreak = 0
    countedIdleLong = 0
    snoozes = 0
    presence = .active
    if let since = s.manualPausedSince {
      if let until = s.manualPauseUntil, wallClock >= until {
        manualPause = .none
      } else {
        manualPause = .paused(sinceWall: since, untilWall: s.manualPauseUntil)
      }
    } else {
      manualPause = .none
    }
    phase = .working
    away(.locked, seconds: max(0, wallClock - s.savedAt), now: now)
  }

  /// The long break that is up (or next) may not be postponed or skipped.
  public var longMustNotDefer: Bool { mustNotDefer(.long) }

  /// A Pausa 时段 window just opened: start the day's counters fresh.
  public mutating func startFresh(now: Double) {
    if case .onBreak = phase { return }
    sinceBreak = 0; breaksSinceLong = 0; snoozes = 0
    consecutiveSkips = 0; consecutiveShortSkips = 0; lastShortSkipped = false
    unengagedIdle = 0; countedIdleBreak = 0; countedIdleLong = 0
    sinceLongDone = 0; clearDeferral()
    lastTick = now
    phase = .working
  }

  /// Seconds the menu's +5分 / +15分 may still push back the next break. Shares the deferral
  /// budget, and a long break may never be pushed past the hard line.
  public var postponeLeft: Double {
    let (kind, remaining, _) = next
    var left = deferralLeft
    if kind == .long { left = min(left, max(0, config.hardLine - sinceLongDone - remaining)) }
    if case .onBreak = phase { return 0 }
    return left
  }

  public func canPostpone(by seconds: Double) -> Bool { postponeLeft >= seconds }

  /// Total postpone allowance of a break type (not what is left): the menu hides
  /// 「休息延后 15 分钟」 when this is under 15 minutes.
  public func postponeBudget(_ kind: BreakKind) -> Double { config.deferBudget(kind) }

  /// Active time since the last *completed* long break, for the menu's 「距上次长休息」 row.
  public var sinceLastLongBreak: Double { sinceLongDone }

  /// The hard line is what limits postponing (not the budget): for the popover's reason line.
  public var atHardLine: Bool {
    let (kind, remaining, _) = next
    return kind == .long && (mustNotDefer(.long) || sinceLongDone + remaining >= config.hardLine)
  }

  /// Menu bar "+5分 / +15分": push the next break back. Returns false (and does nothing) when the
  /// budget or the hard line doesn't allow it; the button should already be greyed out.
  @discardableResult
  public mutating func postpone(by seconds: Double) -> Bool {
    guard seconds > 0, canPostpone(by: seconds) else { return false }
    sinceBreak -= seconds
    deferUsed += seconds
    switch phase {
    case .warning, .deferred:
      let (kind, rem, _) = next
      if rem > config.warnLead {
        phase = .working
      } else if rem > 0 {
        phase = .warning(kind, cardOpened: Int(rem.rounded(.up)) >= PreBreakState.minOpenSeconds)
      }
    case .working, .onBreak, .paused:
      break
    }
    return true
  }

  /// The pre-break panel's 「跳过休息」: skip the short break that is only announced, not yet on
  /// screen. `finish` needs a running break, so the announcement phase has its own entry point.
  /// Only a short break in the warning phase (and never two consecutive short skips); counts as a skip.
  public mutating func skipUpcoming(now: Double) -> [Command] {
    guard case .warning(.short, _) = phase, !lastShortSkipped else { return [] }
    phase = .working
    clearDeferral()
    consecutiveSkips += 1
    consecutiveShortSkips += 1
    lastShortSkipped = true
    reset(.short, done: false)
    if consecutiveShortSkips >= 2 {
      breaksSinceLong += 1
    }
    return [.recorded(.short, planned: config.shortLength, .skipped)]
  }

  /// What the pre-break panel and cursor pill show right now, or nil when neither does. Derived
  /// from the scheduler's state on every read, so it can never lag behind `postpone`, `breakNow`,
  /// `skipUpcoming` or a pause. Paused, away, on a break, or more than `warnLead` away: nil.
  public var preBreak: PreBreakState? {
    if case .paused = manualPause { return nil }
    if isAway { return nil }
    switch phase {
    case .working, .paused, .onBreak:
      return nil
    case .warning(let kind, let cardOpened):
      let (nextKind, remaining, _) = next
      guard nextKind == kind, remaining > 0, remaining <= config.warnLead else { return nil }
      let left = max(0, Int(remaining.rounded(.up)))
      return makePreBreakState(
        kind: kind, secondsLeft: left, typingWait: false,
        showCard: cardOpened || left >= PreBreakState.minOpenSeconds,
        showPill: left <= PreBreakState.pillSeconds)
    case .deferred(let kind, let substate) where substate.showsTypingPill:
      return makePreBreakState(
        kind: kind, secondsLeft: 0, typingWait: true,
        showCard: false, showPill: true)
    case .deferred:
      return nil
    }
  }

  private func makePreBreakState(kind: BreakKind, secondsLeft: Int, typingWait: Bool,
                                 showCard: Bool, showPill: Bool) -> PreBreakState {
    let hard = atHardLine
    let snooze: PreBreakState.Snooze
    if hard { snooze = .hidden }
    else if canPostpone(by: config.snoozeLength) { snooze = .available(minutes: Int(config.snoozeLength / 60)) }
    else { snooze = .usedUp }
    return PreBreakState(
      kind: kind, secondsLeft: secondsLeft, snooze: snooze,
      canSkip: kind == .short && !lastShortSkipped, atHardLine: hard,
      typingWait: typingWait, showCard: showCard, showPill: showPill)
  }

  /// Menu bar "立即休息".
  public mutating func breakNow(_ kind: BreakKind, now: Double) -> [Command] { startBreak(kind, now: now) }

  /// Same rule for every hold (meeting, screen share, video): see below.
  /// Rule: a long break is owed after a meeting if the meeting lasted >= meetingLongMin, or if the
  /// long break is within meetingNearLong of due (or overdue). It is then due afterMeetingDelay
  /// after the meeting ends (normal heads-up first), and the short break is held so it can't
  /// fire in between; past the hard line it starts the tick the hold ends. Otherwise both
  /// counters resume where they were.
  mutating func meetingEnded(lasted: Double) {
    let longNear = next.kind == .long && next.remaining <= config.meetingNearLong
    guard lasted >= config.meetingLongMin || longNear || mustNotDefer(.long) else { return }
    breaksSinceLong = max(0, config.longEveryNth - 1)   // the next break is the long one
    // Past the hard line (reached before or during the hold) it is owed now: no 3-minute
    // wait and no heads-up, and the long-break clock is not restarted (Steve, 2026-10-19).
    sinceBreak = mustNotDefer(.long) ? config.breakEvery : config.breakEvery - config.afterMeetingDelay
  }

  /// A break ended. Short ones count toward the cycle whether taken or skipped; only a completed
  /// long break starts a new cycle, a skipped one stays owed.
  private mutating func reset(_ kind: BreakKind, done: Bool) {
    snoozes = 0
    sinceBreak = 0
    countedIdleBreak = 0
    if kind == .long { if done { breaksSinceLong = 0 } } else { breaksSinceLong += 1 }
  }
}

/// 倒计时 menu-bar ring: which of `steps` visible steps a fraction falls in (redraw only on change).
/// Paused shows the empty dashed ring, so it is step 0.
public func ringStep(fraction: Double, paused: Bool, steps: Int = 24) -> Int {
  guard !paused, fraction.isFinite else { return 0 }
  return min(steps, max(0, Int((fraction * Double(steps)).rounded(.down))))
}
