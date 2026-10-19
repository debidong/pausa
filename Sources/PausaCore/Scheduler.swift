import Foundation

// Pure break scheduler. No timers, no UI, no wall clock: the caller feeds it
// monotonic time (seconds, including sleep) and current signals. Everything
// that can go wrong with timing lives here, so it is all unit-testable.

public enum BreakKind: String, Codable, Equatable { case short, long }

public enum PauseReason: Hashable, Comparable {
  // order = display priority
  case meeting, screenSharing   // "holds": person still at the screen, never interrupted on screen
  case video                    // hold, but bounded by the deferral budget and the 90-minute rule
  case fullscreen
  case outsideHours          // outside the user's Pausa 时段 (lowest priority)
}

/// A soft reason to push a due break back a little (design §0 R1). Sources only say what they
/// are and how long they may defer one break; the scheduler owns all timing (one shared budget).
public enum DeferralKind: Hashable {
  case typing, focusApp, focusMode
  case microphone   // mic on, not yet long enough to count as a meeting
  /// Firm: holds even past the shared budget and the 90-minute line, for at most its own cap. Only
  /// the mic, so a call's first minute never gets a break on screen.
  var firm: Bool { self == .microphone }
}

public struct Deferral: Hashable {
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

public enum AwayKind { case locked, idle }   // locked covers lid-close/sleep/screen lock

public enum BreakOutcome { case completed, skipped, snoozed }

public struct Config: Equatable {
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
  // After a meeting (see Scheduler.meetingEnded).
  public var meetingLongMin: Double = 30 * 60   // a meeting this long earns a long break
  public var meetingNearLong: Double = 5 * 60   // or the long break was this close (or overdue)
  public var afterMeetingDelay: Double = 3 * 60 // long break due this long after the meeting ends
  // Unified deferral budget (design §0).
  public var longDeferBudget: Double = 30 * 60
  public var shortDeferBudget: Double = 10 * 60
  public var hardLine: Double = Double(Config.hardLineMinutes * 60)   // since last completed long break
  /// The 90-minute line, in minutes: one definition for hardLine and the settings caps below.
  public static let hardLineMinutes = 90
  public init() {}

  /// Shared deferral budget and length of each kind of break.
  func deferBudget(_ kind: BreakKind) -> Double { kind == .long ? longDeferBudget : shortDeferBudget }
  func length(_ kind: BreakKind) -> Double { kind == .long ? longLength : shortLength }

  /// Old name, kept for callers that still say "short".
  public var shortEvery: Double { get { breakEvery } set { breakEvery = newValue } }

  /// interval × N may not exceed the 90-minute line (settings grey out the rest).
  public static func allows(everyMin: Int, nth: Int) -> Bool { nth >= 1 && everyMin * nth <= hardLineMinutes }

  /// Settings show "短休息 [count] 次后进行一次长休息": count = short breaks between long ones = N − 1.
  public static func count(fromNth n: Int) -> Int { max(1, n - 1) }
  public static func nth(fromCount c: Int) -> Int { max(1, c) + 1 }
  /// The 90-minute cap in count terms: interval × (count + 1) ≤ 90 (same Config.allows).
  public static func allows(everyMin: Int, count: Int) -> Bool { allows(everyMin: everyMin, nth: nth(fromCount: count)) }

  /// Migrate the old "long break every M minutes" to the nearest N for interval `everyMin`.
  public static func nth(forLegacyLongEveryMin m: Int, everyMin: Int) -> Int {
    guard everyMin > 0 else { return 3 }
    let maxN = max(2, hardLineMinutes / everyMin)
    let n = Int((Double(m) / Double(everyMin)).rounded())
    return min(maxN, max(2, n))
  }
}

public enum Phase: Equatable {
  case working
  case warning(BreakKind)                   // heads-up shown, break imminent
  case onBreak(BreakKind, endsAt: Double)
  case paused(PauseReason)                  // highest-priority reason
}

public enum Command: Equatable {
  case showWarning(BreakKind, secondsLeft: Double)
  case startBreak(BreakKind, length: Double)
  case resumeBreak(BreakKind, remaining: Double)   // back from a lock mid-break: show the rest
  case recorded(BreakKind, planned: Double, BreakResult)   // a break ended for good: one stats row
  case endBreak
}

public struct Scheduler {
  public var config: Config
  public private(set) var phase: Phase = .working

  // Active work time since the last break (any kind), and breaks since the last long one.
  private(set) var sinceBreak: Double = 0
  private(set) var breaksSinceLong = 0
  private var lastTick: Double?
  private var dueSince: Double?
  private var snoozes = 0
  private var breakLength: Double?             // set length of the break on screen, for stats
  private var meetingSince: Double?            // any hold (meeting / screen share / video) started
  private var sinceLongDone: Double = 0          // active time since last *completed* long break
  private var deferUsed: Double = 0              // shared budget used for the current due break
  private var deferBySource: [DeferralKind: Double] = [:]
  private var noDeferNextLong = false            // set by skipping past the 90-minute line
  public private(set) var deferring: DeferralKind?   // for the menu bar, nil when not deferring
  static let holds: Set<PauseReason> = [.meeting, .screenSharing, .video, .fullscreen]
  static let boundedHolds: Set<PauseReason> = [.video, .fullscreen]

  public init(config: Config = Config()) { self.config = config }

  /// Seconds until the next break and which one, for the menu bar.
  public var next: (kind: BreakKind, remaining: Double, fraction: Double) {
    let kind: BreakKind = breaksSinceLong + 1 >= max(1, config.longEveryNth) ? .long : .short
    return (kind, max(0, config.breakEvery - sinceBreak), min(1, max(0, sinceBreak) / config.breakEvery))
  }

  /// Which break in the cycle comes next, 1-based (「第 2 次 / 共 3 次」).
  public var cycle: (index: Int, of: Int) { (min(breaksSinceLong + 1, max(1, config.longEveryNth)), max(1, config.longEveryNth)) }

  /// Seconds until each kind of break is due, for the menu's two countdown rows.
  public var remaining: (short: Double, long: Double) {
    let r = next.remaining
    let toLong = max(0, config.longEveryNth - 1 - breaksSinceLong)
    return (next.kind == .short ? r : r + config.breakEvery, r + Double(toLong) * config.breakEvery)
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

  /// 90-minute line reached, or the user already skipped past it: the long break may not wait.
  private func mustNotDefer(_ kind: BreakKind) -> Bool {
    kind == .long && (sinceLongDone >= config.hardLine || noDeferNextLong)
  }

  /// Call about once a second.
  public mutating func tick(now: Double, reasons: Set<PauseReason>, inputIdle: Double) -> [Command] {
    tick(now: now, reasons: reasons, deferrals: [], inputIdle: inputIdle)
  }

  public mutating func tick(now: Double, reasons inReasons: Set<PauseReason>, deferrals: [Deferral],
                            inputIdle: Double) -> [Command] {
    let dt = lastTick.map { max(0, now - $0) } ?? 0
    lastTick = now
    var reasons = inReasons
    deferring = nil

    if case .onBreak(_, let endsAt) = phase {
      if now >= endsAt { return finish(.completed, now: now) }
      return []
    }

    // Meetings: the person is still sitting at the screen, so meeting time counts toward the
    // long break ("get up") but not the short one (eyes are on faces/slides, and a 20 s break
    // can't happen mid-call anyway).
    let due = next.remaining <= 0
    if !reasons.isDisjoint(with: Self.holds) {
      if next.kind == .long { sinceBreak += dt }   // sitting counts toward "get up", not toward eyes
      sinceLongDone += dt
      // A break held by a hold eats the shared budget (wall clock, once, however many sources).
      if due { deferUsed += dt }
      let kind = next.kind
      let budget = config.deferBudget(kind)
      // Video and fullscreen are bounded: past the budget or the 90-minute line it stops holding. Meetings and
      // screen sharing keep waiting (no overlay on someone else's screen); the break follows after.
      if due && !reasons.isDisjoint(with: Self.boundedHolds) && (deferUsed >= budget || mustNotDefer(kind)) {
        reasons.subtract(Self.boundedHolds)
        if reasons.isDisjoint(with: Self.holds) { meetingSince = nil }   // forced, not "ended": no make-up
      }
    }
    if !reasons.isDisjoint(with: Self.holds) {
      if meetingSince == nil { meetingSince = now }
    } else if let start = meetingSince {
      meetingSince = nil
      meetingEnded(lasted: now - start)
    }

    if let top = reasons.min() {
      phase = .paused(top)
      dueSince = nil
      return []
    }
    if case .paused = phase { phase = .working }

    sinceBreak += dt
    sinceLongDone += dt

    let (kind, remaining, _) = next
    if remaining > config.warnLead { phase = .working; dueSince = nil; return [] }
    if remaining > 0 {
      if phase != .warning(kind) { phase = .warning(kind); return [.showWarning(kind, secondsLeft: remaining)] }
      return []
    }

    // Due. Soft deferrals share one budget; each is also limited by its own cap.
    let budget = config.deferBudget(kind)
    let hard = mustNotDefer(kind)
    let usable = deferrals.filter { d in
      d.kinds.contains(kind) && (deferBySource[d.kind] ?? 0) < d.cap
        // R20: past the 90-minute line nothing defers the long break, not even typing. A firm
        // deferral (the mic, at most a minute) waits to learn whether it is a meeting.
        && (d.kind.firm || (!hard && deferUsed < budget))
    }
    if !usable.isEmpty {
      deferUsed += dt
      for d in usable { deferBySource[d.kind, default: 0] += dt }
      deferring = usable.contains { $0.kind == .typing } ? .typing : usable[0].kind
      return []
    }

    // Wait for a pause in typing, but not forever (R19, R21): the wait comes out of the shared
    // budget, and stops when the budget is spent or the 90-minute line is reached.
    let since = dueSince ?? now
    dueSince = since
    if !hard && deferUsed < budget && inputIdle < config.typingIdle && now - since < config.typingGrace {
      deferUsed += dt
      return []
    }
    dueSince = nil
    return startBreak(kind, now: now)
  }

  private mutating func startBreak(_ kind: BreakKind, now: Double) -> [Command] {
    let length = config.length(kind)
    phase = .onBreak(kind, endsAt: now + length)
    breakLength = length
    return [.startBreak(kind, length: length)]
  }

  private mutating func clearDeferral() { deferUsed = 0; deferBySource = [:] }

  /// User skipped, snoozed, or the overlay finished.
  public mutating func finish(_ outcome: BreakOutcome, now: Double) -> [Command] {
    guard case .onBreak(let kind, _) = phase else { return [] }
    // Past the 90-minute line the long break can't be skipped or snoozed, whatever the UI shows.
    if kind == .long && outcome != .completed && mustNotDefer(.long) { return [] }
    phase = .working
    clearDeferral()
    // A snooze inside the limit is not a result yet: the same break comes back and ends once.
    // Past the limit it is reset like a skip, so it counts as one.
    var result: BreakResult?
    switch outcome {
    case .completed:
      result = .completed
      if kind == .long { sinceLongDone = 0; noDeferNextLong = false }
      reset(kind)   // counts toward the cycle
    case .skipped:
      result = .skipped
      reset(kind)   // a skip is not a completed long break: sinceLongDone keeps counting
    case .snoozed where snoozes < config.maxSnoozes:
      snoozes += 1
      let back = config.snoozeLength
      sinceBreak = config.breakEvery - back   // same break comes back; the cycle count is unchanged
    case .snoozed:
      result = .skipped
      reset(kind)
    }
    let planned = breakLength ?? config.length(kind)
    breakLength = nil
    return (result.map { [.recorded(kind, planned: planned, $0)] } ?? []) + [.endBreak]
  }

  /// The machine was away (locked, lid closed, or idle) for `seconds`.
  /// Call on return; time spent away is never counted as work.
  /// Locked during a break: the locked time counts toward that break (endsAt is on the same
  /// clock, which includes sleep). Back before it ends: the break resumes with what is left.
  /// Back after: the break is completed, exactly as if the overlay had run out.
  @discardableResult
  public mutating func away(_ kind: AwayKind, seconds: Double, now: Double) -> [Command] {
    switch kind {
    case .locked:
      // Screen off: none of this time is work, and it rests the eyes.
      lastTick = now
      if case .onBreak(let k, let endsAt) = phase {
        if now >= endsAt { return finish(.completed, now: now) }
        return [.resumeBreak(k, remaining: endsAt - now)]
      }
      if seconds >= config.longLength { reset(.long); sinceLongDone = 0; noDeferNextLong = false; clearDeferral() }
      else if seconds >= config.shortLength { snoozes = 0; sinceBreak = 0 }   // eyes rested, cycle unchanged
    case .idle:
      // Not touching input != eyes rested (reading code, watching). The short-break
      // clock keeps running; only the long break ("get up") is offset.
      if seconds >= config.longLength { breaksSinceLong = 0 }
    }
    return []
  }

  /// 暂停提醒 1 小时 (Steve, round 7b): no reminders at all, but the time since the last long break
  /// keeps counting. Idle for at least a long break counts as a long break taken. The short clock and
  /// the postpone budget (deferUsed) are untouched.
  public mutating func manualPauseTick(now: Double, inputIdle: Double) {
    let dt = lastTick.map { max(0, now - $0) } ?? 0
    lastTick = now
    if case .onBreak = phase { return }
    sinceLongDone += dt
    if inputIdle >= config.longLength {
      breaksSinceLong = 0; sinceLongDone = 0; noDeferNextLong = false
    }
  }

  /// The manual pause ended (expired or 恢复提醒). Past the 90-minute line the long break starts now
  /// and can't be deferred (mustNotDefer); otherwise counting simply resumes.
  public mutating func manualPauseEnded(now: Double) -> [Command] {
    lastTick = now
    if case .onBreak = phase { return [] }
    guard sinceLongDone >= config.hardLine else { return [] }
    dueSince = nil
    return startBreak(.long, now: now)
  }

  /// What survives a quit / relaunch (design: persistence). Wall clock, not monotonic: the
  /// monotonic clock restarts with the process, so the gap is measured with `Date`.
  public struct Saved: Codable, Equatable {
    public var sinceLongDone: Double
    public var deferUsed: Double
    public var noDeferNextLong: Bool
    public var sinceBreak: Double
    public var breaksSinceLong: Int
    public var savedAt: Double              // wall clock, seconds since 1970
  }

  /// Snapshot for UserDefaults. A running break is saved as not taken (it never completed).
  public func saved(wallClock: Double) -> Saved {
    Saved(sinceLongDone: sinceLongDone, deferUsed: deferUsed, noDeferNextLong: noDeferNextLong,
          sinceBreak: sinceBreak, breaksSinceLong: breaksSinceLong, savedAt: wallClock)
  }

  /// At launch: pick up where the last run stopped. The time the app was not running is treated
  /// like a locked screen: at least `longLength` of it counts as a long break taken (both the
  /// 90-minute clock and the defer budget reset); shorter gaps leave the counters as they were,
  /// so the 90-minute line (mustNotDefer) survives a restart. A wall clock that moved backwards
  /// counts as no gap.
  public mutating func restore(_ s: Saved, wallClock: Double, now: Double) {
    sinceLongDone = max(0, s.sinceLongDone)
    deferUsed = max(0, s.deferUsed)
    deferBySource = [:]
    noDeferNextLong = s.noDeferNextLong
    sinceBreak = s.sinceBreak
    breaksSinceLong = max(0, s.breaksSinceLong)
    dueSince = nil
    snoozes = 0
    phase = .working
    away(.locked, seconds: max(0, wallClock - s.savedAt), now: now)
  }

  /// The long break that is up (or next) may not be postponed or skipped.
  public var longMustNotDefer: Bool { mustNotDefer(.long) }

  /// A Pausa 时段 window just opened: start the day's counters fresh.
  public mutating func startFresh(now: Double) {
    if case .onBreak = phase { return }
    sinceBreak = 0; breaksSinceLong = 0; snoozes = 0; dueSince = nil
    sinceLongDone = 0; noDeferNextLong = false; clearDeferral()
    lastTick = now
    phase = .working
  }

  /// Seconds the menu's +5分 / +15分 may still push back the next break. Shares the deferral
  /// budget, and a long break may never be pushed past the 90-minute line.
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

  /// The 90-minute line is what limits postponing (not the budget): for the popover's reason line.
  public var atHardLine: Bool {
    let (kind, remaining, _) = next
    return kind == .long && (mustNotDefer(.long) || sinceLongDone + remaining >= config.hardLine)
  }

  /// Menu bar "+5分 / +15分": push the next break back. Returns false (and does nothing) when the
  /// budget or the 90-minute line doesn't allow it; the button should already be greyed out.
  @discardableResult
  public mutating func postpone(by seconds: Double) -> Bool {
    guard seconds > 0, canPostpone(by: seconds) else { return false }
    sinceBreak -= seconds
    deferUsed += seconds
    if case .warning = phase { phase = .working }
    dueSince = nil
    return true
  }

  /// Menu bar "立即休息".
  public mutating func breakNow(_ kind: BreakKind, now: Double) -> [Command] { startBreak(kind, now: now) }

  /// Same rule for every hold (meeting, screen share, video): see below.
  /// Rule: a long break is owed after a meeting if the meeting lasted >= meetingLongMin, or if the
  /// long break is within meetingNearLong of due (or overdue). It is then due afterMeetingDelay
  /// after the meeting ends (normal heads-up first), and the short break is held so it can't
  /// fire in between; past the 90-minute line it starts the tick the hold ends. Otherwise both
  /// counters resume where they were.
  mutating func meetingEnded(lasted: Double) {
    let longNear = next.kind == .long && next.remaining <= config.meetingNearLong
    guard lasted >= config.meetingLongMin || longNear || mustNotDefer(.long) else { return }
    breaksSinceLong = max(0, config.longEveryNth - 1)   // the next break is the long one
    // Past the 90-minute line (reached before or during the hold) it is owed now: no 3-minute
    // wait and no heads-up, and the 90-minute clock is not restarted (Steve, 2026-10-19).
    sinceBreak = mustNotDefer(.long) ? config.breakEvery : config.breakEvery - config.afterMeetingDelay
  }

  private mutating func reset(_ kind: BreakKind) {
    snoozes = 0
    sinceBreak = 0
    breaksSinceLong = kind == .long ? 0 : breaksSinceLong + 1   // skipped breaks count too
  }
}

/// 倒计时 menu-bar ring: which of `steps` visible steps a fraction falls in (redraw only on change).
/// Paused shows the empty dashed ring, so it is step 0.
public func ringStep(fraction: Double, paused: Bool, steps: Int = 24) -> Int {
  guard !paused, fraction.isFinite else { return 0 }
  return min(steps, max(0, Int((fraction * Double(steps)).rounded(.down))))
}
