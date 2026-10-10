import Foundation

// Pure break scheduler. No timers, no UI, no wall clock: the caller feeds it
// monotonic time (seconds, including sleep) and current signals. Everything
// that can go wrong with timing lives here, so it is all unit-testable.

public enum BreakKind: Equatable { case short, long }

public enum PauseReason: Hashable, Comparable {
  case meeting, fullscreen   // order = display priority
}

public enum AwayKind { case locked, idle }   // locked covers lid-close/sleep/screen lock

public enum BreakOutcome { case completed, skipped, snoozed }

public struct Config: Equatable {
  public var shortEvery: Double = 20 * 60
  public var shortLength: Double = 20
  public var longEvery: Double = 50 * 60
  public var longLength: Double = 3 * 60
  public var warnLead: Double = 30          // heads-up before a break
  public var typingGrace: Double = 30       // max wait for user to stop typing
  public var typingIdle: Double = 2         // input gap that counts as "stopped"
  public var snoozeLength: Double = 5 * 60
  public var maxSnoozes = 2
  public init() {}
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
  case endBreak
}

public struct Scheduler {
  public var config: Config
  public private(set) var phase: Phase = .working

  // Active work time since the last break of each kind.
  private(set) var sinceShort: Double = 0
  private(set) var sinceLong: Double = 0
  private var lastTick: Double?
  private var dueSince: Double?
  private var snoozes = 0

  public init(config: Config = Config()) { self.config = config }

  /// Seconds until the next break and which one, for the menu bar.
  public var next: (kind: BreakKind, remaining: Double, fraction: Double) {
    let s = config.shortEvery - sinceShort
    let l = config.longEvery - sinceLong
    if l <= s { return (.long, max(0, l), min(1, sinceLong / config.longEvery)) }
    return (.short, max(0, s), min(1, sinceShort / config.shortEvery))
  }

  /// Call about once a second.
  public mutating func tick(now: Double, reasons: Set<PauseReason>, inputIdle: Double) -> [Command] {
    let dt = lastTick.map { max(0, now - $0) } ?? 0
    lastTick = now

    if case .onBreak(_, let endsAt) = phase {
      if now >= endsAt { return finish(.completed, now: now) }
      return []
    }

    if let top = reasons.min() {
      phase = .paused(top)
      dueSince = nil
      return []
    }
    if case .paused = phase { phase = .working }

    sinceShort += dt
    sinceLong += dt

    let (kind, remaining, _) = next
    if remaining > config.warnLead { phase = .working; dueSince = nil; return [] }
    if remaining > 0 {
      if phase != .warning(kind) { phase = .warning(kind); return [.showWarning(kind, secondsLeft: remaining)] }
      return []
    }

    // Due. Wait for a pause in typing, but not forever.
    let since = dueSince ?? now
    dueSince = since
    if inputIdle < config.typingIdle && now - since < config.typingGrace { return [] }
    dueSince = nil
    let length = kind == .long ? config.longLength : config.shortLength
    phase = .onBreak(kind, endsAt: now + length)
    return [.startBreak(kind, length: length)]
  }

  /// User skipped, snoozed, or the overlay finished.
  public mutating func finish(_ outcome: BreakOutcome, now: Double) -> [Command] {
    guard case .onBreak(let kind, _) = phase else { return [] }
    phase = .working
    switch outcome {
    case .completed, .skipped:
      reset(kind)
    case .snoozed where snoozes < config.maxSnoozes:
      snoozes += 1
      let back = config.snoozeLength
      if kind == .long { sinceLong = config.longEvery - back } else { sinceShort = config.shortEvery - back }
    case .snoozed:
      reset(kind)
    }
    return [.endBreak]
  }

  /// The machine was away (locked, lid closed, or idle) for `seconds`.
  /// Call on return; time spent away is never counted as work.
  public mutating func away(_ kind: AwayKind, seconds: Double, now: Double) {
    lastTick = now
    if case .onBreak = phase { phase = .working }
    switch kind {
    case .locked:
      if seconds >= config.longLength { reset(.long) }
      else if seconds >= config.shortLength { reset(.short) }
    case .idle:
      // Not touching input != eyes rested (reading, phone). Only offsets the long break.
      if seconds >= config.longLength { sinceLong = 0 }
    }
  }

  /// Menu bar "立即休息".
  public mutating func breakNow(_ kind: BreakKind, now: Double) -> [Command] {
    let length = kind == .long ? config.longLength : config.shortLength
    phase = .onBreak(kind, endsAt: now + length)
    return [.startBreak(kind, length: length)]
  }

  private mutating func reset(_ kind: BreakKind) {
    snoozes = 0
    sinceShort = 0                        // a long break also rests the eyes
    if kind == .long { sinceLong = 0 }
  }
}
