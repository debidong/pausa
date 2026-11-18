import Foundation

/// How a break ended for good. Postpones are not results: a postponed break ends once, later.
public enum BreakResult: String, Codable, Equatable { case completed, skipped }

/// One break, one row. Daily numbers are computed from these when the stats page opens.
public struct BreakRecord: Codable, Equatable {
  public var start: Date
  public var kind: BreakKind
  public var planned: Double   // seconds, the length set when the break started
  public var result: BreakResult
  /// Optional frontmost app active when this break was skipped (for skip attribution).
  public var appBundleID: String?
  public var appName: String?
  /// True when a skipped break was redeemed within 5 minutes by taking a break or locking the screen.
  public var redeemed: Bool

  public init(start: Date, kind: BreakKind, planned: Double, result: BreakResult,
              appBundleID: String? = nil, appName: String? = nil, redeemed: Bool = false) {
    self.start = start
    self.kind = kind
    self.planned = planned
    self.result = result
    self.appBundleID = appBundleID
    self.appName = appName
    self.redeemed = redeemed
  }

  private enum CodingKeys: String, CodingKey {
    case start, kind, planned, result, appBundleID, appName, redeemed
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    start = try c.decode(Date.self, forKey: .start)
    kind = try c.decode(BreakKind.self, forKey: .kind)
    planned = try c.decode(Double.self, forKey: .planned)
    result = try c.decode(BreakResult.self, forKey: .result)
    appBundleID = try c.decodeIfPresent(String.self, forKey: .appBundleID)
    appName = try c.decodeIfPresent(String.self, forKey: .appName)
    redeemed = try c.decodeIfPresent(Bool.self, forKey: .redeemed) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(start, forKey: .start)
    try c.encode(kind, forKey: .kind)
    try c.encode(planned, forKey: .planned)
    try c.encode(result, forKey: .result)
    try c.encodeIfPresent(appBundleID, forKey: .appBundleID)
    try c.encodeIfPresent(appName, forKey: .appName)
    if redeemed { try c.encode(true, forKey: .redeemed) }
  }
}

/// Per-day active screen seconds accumulated for one regular frontmost application.
public struct AppUsageRecord: Codable, Equatable {
  public var day: Date
  public var bundleID: String
  public var appName: String
  public var seconds: Double

  public init(day: Date, bundleID: String, appName: String, seconds: Double) {
    self.day = day
    self.bundleID = bundleID
    self.appName = appName
    self.seconds = seconds
  }
}

/// Aggregated per-app usage and skip count for one calendar day, sorted descending by active screen time.
public struct AppUsageSummary: Equatable {
  public var bundleID: String
  public var name: String
  public var seconds: Double
  public var skipped: Int

  public init(bundleID: String, name: String, seconds: Double, skipped: Int) {
    self.bundleID = bundleID
    self.name = name
    self.seconds = seconds
    self.skipped = skipped
  }
}

public struct DayStats: Equatable {
  public var day: Date          // start of that calendar day
  public var taken = 0, skipped = 0
  public var seconds: Double = 0   // planned length of completed breaks only
  public var work: Double = 0      // seconds of work that fell on this day
  public var gaps: [Double] = []   // per completed break, this day's work before it started (chart §8)
  /// Continuous unbroken work stretches (seconds) in chronological order, cut by completed breaks or away/idle gaps.
  public var stretches: [Double] = []
  public var longestStretch: Double = 0
  /// Eye-care rhythm score in 0...100 (100 = ideal cadence; smoothed prior, 3:1 long/short weights, preset-scaled stretches).
  public var rhythmScore: Int = 100
  /// Top active frontmost apps on this day, with skip counts attributed per app.
  public var apps: [AppUsageSummary] = []

  public init(day: Date) { self.day = day }
}

public enum Stats {
  /// The last `n` calendar days up to and including the day of `now`, oldest first.
  /// A break belongs to the day it started; days without breaks are zero rows.
  /// Work spans are cut at each midnight, so a span over 00:00 adds to both days.
  public static func days(_ records: [BreakRecord], work: [WorkSpan] = [], appUsage: [AppUsageRecord] = [],
                          endingAt now: Date, count n: Int, calendar: Calendar,
                          intervalMinutes: Double = 20, hardLineMinutes: Double = 90) -> [DayStats] {
    let today = calendar.startOfDay(for: now)
    let days = (0..<max(0, n)).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    var out = days.map(DayStats.init(day:))
    let index = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($1, $0) })
    var completedTimes = Array(repeating: [Date](), count: out.count)
    var weightedTaken = Array(repeating: 0.0, count: out.count)
    var weightedSkipped = Array(repeating: 0.0, count: out.count)
    var skipsByApp = Array(repeating: [String: (name: String, count: Int)](), count: out.count)

    for r in records {
      guard let i = index[calendar.startOfDay(for: r.start)] else { continue }
      let weight = r.kind == .long ? 3.0 : 1.0
      switch r.result {
      case .completed:
        out[i].taken += 1; out[i].seconds += r.planned
        weightedTaken[i] += weight
        out[i].gaps.append(worked(work, from: days[i], to: r.start))
        completedTimes[i].append(r.start)
      case .skipped where r.redeemed:
        break
      case .skipped:
        out[i].skipped += 1
        weightedSkipped[i] += weight
        if let bid = r.appBundleID, !bid.isEmpty {
          let prev = skipsByApp[i][bid]
          let resolvedName = (r.appName?.isEmpty == false ? r.appName! : prev?.name) ?? bid
          skipsByApp[i][bid] = (resolvedName, (prev?.count ?? 0) + 1)
        }
      }
    }

    var usageByDay = Array(repeating: [String: (name: String, seconds: Double)](), count: out.count)
    for u in appUsage where u.seconds > 0 && !u.bundleID.isEmpty {
      guard let i = index[calendar.startOfDay(for: u.day)] else { continue }
      let prev = usageByDay[i][u.bundleID]
      let name = u.appName.isEmpty ? (prev?.name ?? u.bundleID) : u.appName
      usageByDay[i][u.bundleID] = (name, (prev?.seconds ?? 0) + u.seconds)
    }

    let nonHoldWork = work.filter { !$0.isHold }
    for (i, day) in days.enumerated() {
      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
      out[i].work = worked(work, from: day, to: next)
      out[i].gaps.sort()
      out[i].stretches = computeStretches(work: work, completed: completedTimes[i], from: day, to: next, totalWork: out[i].work)
      out[i].longestStretch = out[i].stretches.max() ?? 0
      let nonHoldTotal = worked(nonHoldWork, from: day, to: next)
      let scoreStretches = computeStretches(work: nonHoldWork, completed: completedTimes[i], from: day, to: next, totalWork: nonHoldTotal)
      out[i].rhythmScore = computeRhythmScore(
        work: out[i].work,
        taken: out[i].taken,
        skipped: out[i].skipped,
        stretches: scoreStretches,
        weightedTaken: weightedTaken[i],
        weightedSkipped: weightedSkipped[i],
        intervalMinutes: intervalMinutes,
        hardLineMinutes: hardLineMinutes
      )
      out[i].apps = mergeAppSummaries(usage: usageByDay[i], skips: skipsByApp[i], dayWork: out[i].work)
    }
    return out
  }

  /// Seconds of `work` inside [from, to).
  static func worked(_ work: [WorkSpan], from: Date, to: Date) -> Double {
    work.reduce(0) { sum, w in
      let s = max(w.start, from), e = min(w.end, to)
      return e > s ? sum + e.timeIntervalSince(s) : sum
    }
  }

  /// Slices clipped work spans by completed breaks and away/idle gaps (> 15 s) into chronological continuous stretches.
  static func computeStretches(work: [WorkSpan], completed: [Date], from: Date, to: Date, totalWork: Double) -> [Double] {
    guard totalWork > 0 else { return [] }
    let clipped = work.compactMap { w -> (Date, Date)? in
      let s = max(w.start, from), e = min(w.end, to)
      return e > s ? (s, e) : nil
    }.sorted { $0.0 < $1.0 }
    guard !clipped.isEmpty else { return [] }

    let cuts = completed.sorted()
    // Merge micro-adjacent spans (< 15 s apart) only when no completed break fell between them.
    var merged: [(Date, Date)] = []
    for seg in clipped {
      if let last = merged.last,
         seg.0.timeIntervalSince(last.1) <= 15,
         !cuts.contains(where: { $0 >= last.1 && $0 <= seg.0 }) {
        merged[merged.count - 1].1 = max(last.1, seg.1)
      } else {
        merged.append(seg)
      }
    }

    // Split any span that contains interior completed break timestamps.
    var pieces: [Double] = []
    for (segStart, segEnd) in merged {
      var cursor = segStart
      for cut in cuts where cut > cursor && cut < segEnd {
        pieces.append(cut.timeIntervalSince(cursor))
        cursor = cut
      }
      if segEnd > cursor {
        pieces.append(segEnd.timeIntervalSince(cursor))
      }
    }

    let meaningful = pieces.filter { $0 >= 30 }
    return meaningful.isEmpty ? [totalWork] : meaningful
  }

  /// Objective 0–100 eye-care cadence score starting at 100, with Bayesian prior smoothing (+4),
  /// 3:1 long-vs-short skip weight, and interval-scaled stretch thresholds (`1.25×` and `2.0×`).
  public static func computeRhythmScore(
    work: Double,
    taken: Int,
    skipped: Int,
    stretches: [Double],
    weightedTaken: Double? = nil,
    weightedSkipped: Double? = nil,
    intervalMinutes: Double = 20,
    hardLineMinutes: Double = 90
  ) -> Int {
    if work <= 0 && taken == 0 && skipped == 0 { return 100 }
    let wTaken = weightedTaken ?? Double(taken)
    let wSkipped = weightedSkipped ?? Double(skipped)
    let totalWeighted = wTaken + wSkipped
    let skipRatioPenalty = totalWeighted > 0 ? 28.0 * (wSkipped / (totalWeighted + 4.0)) : 0
    let skipCountPenalty = min(wSkipped, 12.0) * 1.5

    let baseInterval = max(10.0, intervalMinutes)
    let tau1 = 1.25 * baseInterval
    let tau2 = max(tau1 + 5.0, min(max(baseInterval, hardLineMinutes), 2.0 * baseInterval))
    let tier1Span = max(1.0, tau2 - tau1)

    var stretchPenalty = 0.0
    for sec in stretches {
      let mins = sec / 60.0
      if mins > tau1 {
        stretchPenalty += min(mins - tau1, tier1Span) * 0.25
      }
      if mins > tau2 {
        stretchPenalty += (mins - tau2) * 0.70
      }
    }

    let raw = 100.0 - skipRatioPenalty - skipCountPenalty - stretchPenalty
    return max(20, min(100, Int(raw.rounded())))
  }

  private static func mergeAppSummaries(
    usage: [String: (name: String, seconds: Double)],
    skips: [String: (name: String, count: Int)],
    dayWork: Double
  ) -> [AppUsageSummary] {
    let allIDs = Set(usage.keys).union(skips.keys)
    let minSeconds = dayWork < 60 ? 1.0 : 15.0
    var list: [AppUsageSummary] = []
    for id in allIDs {
      let u = usage[id]
      let sk = skips[id]
      let secs = u?.seconds ?? 0
      let skipCount = sk?.count ?? 0
      guard secs >= minSeconds || skipCount > 0 else { continue }
      let name = u?.name ?? sk?.name ?? id
      list.append(AppUsageSummary(bundleID: id, name: name, seconds: secs, skipped: skipCount))
    }
    list.sort {
      if abs($0.seconds - $1.seconds) > 0.5 { return $0.seconds > $1.seconds }
      if $0.skipped != $1.skipped { return $0.skipped > $1.skipped }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    return Array(list.prefix(5))
  }
}

/// A stretch of work: time Pausa would remind the user, while they were using the Mac.
/// Stored as is; split at midnight only when the stats page adds it up.
public struct WorkSpan: Codable, Equatable {
  public var start: Date
  public var end: Date
  /// True when auto-paused for a meeting or screen share (counted in screen time, exempt from focus-stretch penalty).
  public var isHold: Bool

  public init(start: Date, end: Date, isHold: Bool = false) {
    self.start = start
    self.end = end
    self.isHold = isHold
  }

  private enum CodingKeys: String, CodingKey {
    case start, end, isHold
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    start = try c.decode(Date.self, forKey: .start)
    end = try c.decode(Date.self, forKey: .end)
    isHold = try c.decodeIfPresent(Bool.self, forKey: .isHold) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(start, forKey: .start)
    try c.encode(end, forKey: .end)
    if isHold { try c.encode(true, forKey: .isHold) }
  }
}

/// Opens and closes work spans from what the app already knows each tick. Monotonic seconds in,
/// closed spans out; the caller turns them into dates.
///
/// Idle uses the decoupled 5-minute threshold (`Config.idleFreezeThreshold`, independent of `longLength`):
/// past it, the whole stretch since the last input is not work, so the span ends when input stopped,
/// not when the line was crossed.
public struct WorkClock: Equatable {
  public static let defaultIdleLimit: Double = 5 * 60
  public private(set) var openedAt: Double?
  public init() {}

  /// `counting`: Pausa would remind now (active hours, not quiet hours), no break on screen, not locked.
  /// 暂停提醒 still counts. `holding`: a meeting, screen share, video or full screen, where the
  /// scheduler already treats the person as at the screen; idle does not end the span then.
  public mutating func update(now: Double, counting: Bool, holding: Bool = false, inputIdle: Double,
                              idleLimit: Double = WorkClock.defaultIdleLimit) -> (start: Double, end: Double)? {
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

/// The 7-day chart (spec §8): bar height is work time, the axis top is the longest day in
/// 8...24 hours. A 1 pt gap at `barHeight(work: gap, ...)` marks each completed break.
public enum StatsChart {
  public static let plotHeight: Double = 240
  public static let scale: ClosedRange<Double> = 8 * 3600 ... 24 * 3600
  public static let barWidthRatio: Double = 0.72

  /// Points from the bar's base for `work` seconds when the longest day in view had `longest`.
  public static func barHeight(work: Double, longest: Double) -> Double {
    let top = min(max(longest, scale.lowerBound), scale.upperBound)
    return work <= 0 ? 0 : plotHeight * min(work, top) / top
  }

  public enum Label: Equatable { case hours(String), minutes(Int) }   // 「6.3 小时」 / 「45 分钟」
  /// nil for a day without work: no label, only the 2 pt line. `locale` picks the decimal mark (fr: 「6,3」).
  public static func label(_ work: Double, locale: Locale = Locale(identifier: "en_US_POSIX")) -> Label? {
    guard work > 0 else { return nil }
    if work < 3600 { return .minutes(Int(work) / 60) }
    return .hours(String(format: "%.1f", locale: locale, work / 3600))
  }
}

/// Adaptive y-axis scale for the redesigned 7-day / 30-day trend chart (eliminates dead headroom on 2–6 h weeks).
public enum StatsTrendScale {
  public static let hourSteps = [2, 4, 5, 6, 8, 10, 12, 16, 24]
  public static let plotHeight: Double = 104

  public static func ceilingHours(longest: Double) -> Int {
    let target = max(2 * 3600.0, longest * 1.03)
    return hourSteps.first { Double($0) * 3600.0 >= target } ?? 24
  }

  public static func barHeight(work: Double, longest: Double, maxHeight: Double = plotHeight) -> Double {
    guard work > 0 else { return 0 }
    let top = Double(ceilingHours(longest: longest)) * 3600.0
    return max(3.5, maxHeight * min(work, top) / top)
  }
}
