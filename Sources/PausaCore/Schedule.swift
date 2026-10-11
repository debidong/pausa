import Foundation

/// "Pausa 时段" (active hours). Pure logic: wall-clock comparisons through a Calendar,
/// so time-zone changes and DST need no special cases (a DST gap just shortens a window).

/// Local wall-clock time of day, minutes 0..<1440.
public struct ClockTime: Codable, Hashable, Comparable {
    public var minutes: Int
    public init(minutes: Int) { self.minutes = min(max(minutes, 0), 1439) }
    public init(_ h: Int, _ m: Int = 0) { self.init(minutes: h * 60 + m) }
    public static func < (a: ClockTime, b: ClockTime) -> Bool { a.minutes < b.minutes }
}

/// end <= start means the range crosses midnight and belongs to the day it starts on.
public struct ClockRange: Codable, Hashable {
    public var start, end: ClockTime
    public init(_ start: ClockTime, _ end: ClockTime) { self.start = start; self.end = end }
    var crossesMidnight: Bool { end <= start }
}

public struct PausaWindow: Codable, Identifiable, Hashable {
    public var id: UUID
    public var start, end: ClockTime
    public var weekdays: Set<Int>          // Calendar.weekday, 1 = Sunday ... 7 = Saturday
    public var enabled: Bool
    public init(id: UUID = UUID(), start: ClockTime, end: ClockTime, weekdays: Set<Int>, enabled: Bool = true) {
        self.id = id; self.start = start; self.end = end; self.weekdays = weekdays; self.enabled = enabled
    }
    var range: ClockRange { ClockRange(start, end) }
}

/// A local calendar day.
public struct DateKey: Codable, Hashable {
    public var y, m, d: Int
    public init(y: Int, m: Int, d: Int) { self.y = y; self.m = m; self.d = d }
    public init(_ date: Date, cal: Calendar) {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        self.init(y: c.year!, m: c.month!, d: c.day!)
    }
    /// Noon avoids DST edges (no zone shifts at 12:00).
    func noon(_ cal: Calendar) -> Date? { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) }
    func adding(days: Int, _ cal: Calendar) -> DateKey? {
        guard let n = noon(cal), let o = cal.date(byAdding: .day, value: days, to: n) else { return nil }
        return DateKey(o, cal: cal)
    }
    func weekday(_ cal: Calendar) -> Int? { noon(cal).map { cal.component(.weekday, from: $0) } }
}

/// One side of the schedule: weekly windows plus extra windows on specific dates.
public struct HoursSet: Codable, Hashable {
    public var rules: [PausaWindow]
    public var dates: [DateKey: [ClockRange]]
    public init(rules: [PausaWindow] = [], dates: [DateKey: [ClockRange]] = [:]) { self.rules = rules; self.dates = dates }

    /// Ranges that start on `day`: enabled weekly rules for its weekday, plus that date's entries.
    func ranges(on day: DateKey, _ cal: Calendar) -> [ClockRange] {
        var out = dates[day] ?? []
        if let wd = day.weekday(cal) { out += rules.filter { $0.enabled && $0.weekdays.contains(wd) }.map(\.range) }
        return out
    }

    func contains(_ t: Date, _ cal: Calendar) -> Bool {
        let c = cal.dateComponents([.hour, .minute], from: t)
        let m = ClockTime(c.hour ?? 0, c.minute ?? 0)
        let today = DateKey(t, cal: cal)
        if ranges(on: today, cal).contains(where: { $0.start <= m && ($0.crossesMidnight || m < $0.end) }) { return true }
        guard let prev = today.adding(days: -1, cal) else { return false }
        return ranges(on: prev, cal).contains { $0.crossesMidnight && m < $0.end }
    }
}

/// 00:00 – 00:00: the whole calendar day.
public extension ClockRange { static let allDay = ClockRange(ClockTime(0), ClockTime(0)) }

/// Pausa 时段. include = 提醒时段 (weekly + make-up dates); exclude = 免打扰 (weekly + skipped dates).
/// Active = include && !exclude: exclude always wins. Disabled = always active.
public struct PausaSchedule: Codable, Hashable {
    public var enabled: Bool
    public var include: HoursSet
    public var exclude: HoursSet
    public init(enabled: Bool = false, include: HoursSet = HoursSet(), exclude: HoursSet = HoursSet()) {
        self.enabled = enabled; self.include = include; self.exclude = exclude
    }
    /// Convenience: include-only weekly rules.
    public init(enabled: Bool, rules: [PausaWindow]) { self.init(enabled: enabled, include: HoursSet(rules: rules)) }
    public var rules: [PausaWindow] { get { include.rules } set { include.rules = newValue } }

    // Codable, migrating v1 {enabled, rules, overrides: [DateKey: off | windows]}.
    private enum CodingKeys: String, CodingKey { case enabled, include, exclude, rules, overrides }
    private enum LegacyOverride: Codable { case off; case windows([ClockRange]) }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        if let inc = try c.decodeIfPresent(HoursSet.self, forKey: .include) {
            include = inc
            exclude = try c.decodeIfPresent(HoursSet.self, forKey: .exclude) ?? HoursSet()
            return
        }
        include = HoursSet(rules: try c.decodeIfPresent([PausaWindow].self, forKey: .rules) ?? [])
        exclude = HoursSet()
        // v1 "off" -> skip that date. v1 "custom windows" -> add them as a make-up date (the weekly
        // rules of that day are no longer replaced; v1 never shipped a UI, so nobody has these).
        for (k, o) in try c.decodeIfPresent([DateKey: LegacyOverride].self, forKey: .overrides) ?? [:] {
            switch o {
            case .off: exclude.dates[k] = [.allDay]
            case .windows(let r): include.dates[k] = r
            }
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled); try c.encode(include, forKey: .include); try c.encode(exclude, forKey: .exclude)
    }
}

/// Disabled schedule = always active.
public func isActive(_ s: PausaSchedule, at t: Date, cal: Calendar) -> Bool {
    guard s.enabled else { return true }
    return s.include.contains(t, cal) && !s.exclude.contains(t, cal)
}

/// Window edges (both sets) strictly after `t`, sorted, calling `body` until it returns false.
/// Edges of ranges starting on day D lie in [D 00:00, D+2 00:00), so once day D is added,
/// every pending edge before D 00:00 is final.
func forEachBoundary(_ s: PausaSchedule, after t: Date, cal: Calendar, days: Int, _ body: (Date) -> Bool) {
    let today = DateKey(t, cal: cal)
    var pending: [Date] = []
    func flush(before limit: Date?) -> Bool {
        pending.sort()
        while let f = pending.first, limit == nil || f < limit! {
            pending.removeFirst()
            if !body(f) { return false }
        }
        return true
    }
    for offset in -1...days {
        guard let day = today.adding(days: offset, cal),
              let midnight = cal.date(from: DateComponents(year: day.y, month: day.m, day: day.d)) else { continue }
        if !flush(before: midnight) { return }
        for r in s.include.ranges(on: day, cal) + s.exclude.ranges(on: day, cal) {
            for (mins, plus) in [(r.start.minutes, 0), (r.end.minutes, r.crossesMidnight ? 1 : 0)] {
                guard let d = day.adding(days: plus, cal),
                      let at = cal.date(from: DateComponents(year: d.y, month: d.m, day: d.d, hour: mins / 60, minute: mins % 60)),
                      at > t, !pending.contains(at) else { continue }
                pending.append(at)
            }
        }
    }
    _ = flush(before: nil)
}

/// When reminders next turn on after `t`. nil if disabled or not within 400 days.
public func nextStart(_ s: PausaSchedule, after t: Date, cal: Calendar) -> Date? {
    guard s.enabled else { return nil }
    var was = isActive(s, at: t, cal: cal)
    var found: Date?
    forEachBoundary(s, after: t, cal: cal, days: 400) { b in
        let now = isActive(s, at: b, cal: cal)
        if now && !was { found = b; return false }
        was = now
        return true
    }
    return found
}

/// The next window edge after `t` (isActive may flip there), for the boundary timer.
public func nextChange(_ s: PausaSchedule, after t: Date, cal: Calendar, days: Int = 8) -> Date? {
    guard s.enabled else { return nil }
    var found: Date?
    forEachBoundary(s, after: t, cal: cal, days: days) { found = $0; return false }
    return found
}

/// Edge detector between ticks: reports when a window opens so the caller can start fresh.
public struct HoursGate {
    public private(set) var active: Bool?
    public init() {}
    /// Returns true exactly when going from inactive to active.
    public mutating func update(_ nowActive: Bool) -> Bool {
        defer { active = nowActive }
        return active == false && nowActive
    }
}
