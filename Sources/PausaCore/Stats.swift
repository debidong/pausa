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

public extension Stats {
  /// Oldest moment kept: 00:00 of the first of the last `days` calendar days (today and the 29 before it).
  static func keepFrom(now: Date, days: Int, calendar: Calendar) -> Date {
    let today = calendar.startOfDay(for: now)
    return calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today
  }
}

/// How a duration is written on the stats page (spec §5.4). The words live in L10n; this picks the form.
public enum DurationParts: Equatable {
  case seconds(Int)                 // 1–59 s: 「40 秒」
  case minutes(Int)                 // 0 and 60–3599 s: 「18 分钟」, the rest dropped
  case hours(Int, minutes: Int)     // ≥ 1 h: 「4 小时 12 分钟」, minutes 0 means 「2 小时」
  public init(_ seconds: Double) {
    let s = Int(max(0, seconds))
    switch s {
    case 0: self = .minutes(0)
    case 1..<60: self = .seconds(s)
    case 60..<3600: self = .minutes(s / 60)
    default: self = .hours(s / 3600, minutes: s % 3600 / 60)
    }
  }
}

/// The 7-day chart (spec §8): bar height is work time, the scale never below 8 hours.
public enum StatsChart {
  public static let plotHeight: Double = 150
  public static let minScale: Double = 8 * 3600
  public static let barWidthRatio: Double = 0.72

  /// Points of bar for `work` seconds when the longest day in view had `longest`.
  public static func barHeight(work: Double, longest: Double) -> Double {
    work <= 0 ? 0 : plotHeight * work / max(longest, minScale)
  }

  public enum Label: Equatable { case hours(String), minutes(Int) }   // 「6.3 小时」 / 「45 分钟」
  /// nil for a day without work: no label, only the 2 pt line.
  public static func label(_ work: Double) -> Label? {
    guard work > 0 else { return nil }
    if work < 3600 { return .minutes(Int(work) / 60) }
    return .hours(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), work / 3600))
  }
}
