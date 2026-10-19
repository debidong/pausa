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
  public init(day: Date) { self.day = day }
}

public enum Stats {
  /// The last `n` calendar days up to and including the day of `now`, oldest first.
  /// A break belongs to the day it started; days without breaks are zero rows.
  public static func days(_ records: [BreakRecord], endingAt now: Date, count n: Int, calendar: Calendar) -> [DayStats] {
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
    return out
  }
}
