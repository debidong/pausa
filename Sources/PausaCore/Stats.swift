import Foundation

/// How a break ended for good. Postpones are not results: a postponed break ends once, later.
public enum BreakResult: String, Codable, Equatable { case completed, skipped }

/// One break, one row. Daily numbers are computed from these when the stats page opens.
public struct BreakRecord: Codable, Equatable {
  public var start: Date
  public var kind: BreakKind
  public var planned: Double   // seconds, the length set when the break started
  public var result: BreakResult
  public init(start: Date, kind: BreakKind, planned: Double, result: BreakResult) {
    self.start = start; self.kind = kind; self.planned = planned; self.result = result
  }
}

public struct DayStats: Equatable {
  public var day: Date          // start of that calendar day
  public var taken = 0, skipped = 0
  public var seconds: Double = 0   // planned length of completed breaks only
  public var work: Double = 0      // seconds of work that fell on this day
  public init(day: Date) { self.day = day }
}

public enum Stats {
  /// The last `n` calendar days up to and including the day of `now`, oldest first.
  /// A break belongs to the day it started; days without breaks are zero rows.
  /// Work spans are cut at each midnight, so a span over 00:00 adds to both days.
  public static func days(_ records: [BreakRecord], work: [WorkSpan] = [], endingAt now: Date, count n: Int,
                          calendar: Calendar) -> [DayStats] {
    let today = calendar.startOfDay(for: now)
    let days = (0..<max(0, n)).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    var out = days.map(DayStats.init(day:))
    let index = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($1, $0) })
    for r in records {
      guard let i = index[calendar.startOfDay(for: r.start)] else { continue }
      switch r.result {
      case .completed: out[i].taken += 1; out[i].seconds += r.planned
      case .skipped: out[i].skipped += 1
      }
    }
    for (i, day) in days.enumerated() {
      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
      for w in work {
        let s = max(w.start, day), e = min(w.end, next)
        if e > s { out[i].work += e.timeIntervalSince(s) }
      }
    }
    return out
  }
}

/// A stretch of work: time Pausa would remind the user, while they were using the Mac.
/// Stored as is; split at midnight only when the stats page adds it up.
public struct WorkSpan: Codable, Equatable {
  public var start: Date
  public var end: Date
  public init(start: Date, end: Date) { self.start = start; self.end = end }
}

/// Opens and closes work spans from what the app already knows each tick. Monotonic seconds in,
/// closed spans out; the caller turns them into dates.
///
/// Idle uses the scheduler's own line (`Config.longLength`, the same stretch that offsets the
/// long break): past it, the whole stretch since the last input is not work, so the span ends
/// when input stopped, not when the line was crossed.
public struct WorkClock: Equatable {
  public private(set) var openedAt: Double?
  public init() {}

  /// `counting`: Pausa would remind now (active hours, not quiet hours), no break on screen, not locked.
  /// 暂停提醒 1 小时 still counts. `holding`: a meeting, screen share, video or full screen, where the
  /// scheduler already treats the person as at the screen; idle does not end the span then.
  public mutating func update(now: Double, counting: Bool, holding: Bool = false, inputIdle: Double,
                              idleLimit: Double) -> (start: Double, end: Double)? {
    let idle = !holding && inputIdle >= idleLimit
    if counting && !idle {
      if openedAt == nil { openedAt = now }
      return nil
    }
    return close(at: idle ? now - inputIdle : now)
  }

  /// Close the open span, if any (break starts, lock, quit).
  public mutating func close(at t: Double) -> (start: Double, end: Double)? {
    guard let s = openedAt else { return nil }
    openedAt = nil
    return t > s ? (s, t) : nil
  }
}
