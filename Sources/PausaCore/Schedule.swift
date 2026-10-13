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
    func noon(_ cal: Calendar) -> Date? { at(minutes: 12 * 60, cal) }
    /// Wall-clock `minutes` after this day's 00:00 (0 = midnight).
    func at(minutes: Int, _ cal: Calendar) -> Date? {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: minutes / 60, minute: minutes % 60))
    }
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
    /// `kinds`: 特定日期. A 上班 date counts as a weekday: every rule with any of Mon–Fri ticked
    /// applies (overlaps union, since `contains` checks any range). A 休息 date has no weekly rules.
    func ranges(on day: DateKey, _ cal: Calendar, kinds: [DateKey: DayKind] = [:]) -> [ClockRange] {
        var out = dates[day] ?? []
        switch kinds[day] {
        case .work: out += rules.filter { $0.enabled && !$0.weekdays.isDisjoint(with: 2...6) }.map(\.range)
        case .off: break
        case nil: if let wd = day.weekday(cal) { out += rules.filter { $0.enabled && $0.weekdays.contains(wd) }.map(\.range) }
        }
        return out
    }

    func contains(_ t: Date, _ cal: Calendar, kinds: [DateKey: DayKind] = [:]) -> Bool {
        let c = cal.dateComponents([.hour, .minute], from: t)
        let m = ClockTime(c.hour ?? 0, c.minute ?? 0)
        let today = DateKey(t, cal: cal)
        if ranges(on: today, cal, kinds: kinds).contains(where: { $0.start <= m && ($0.crossesMidnight || m < $0.end) }) { return true }
        guard let prev = today.adding(days: -1, cal) else { return false }
        return ranges(on: prev, cal, kinds: kinds).contains { $0.crossesMidnight && m < $0.end }
    }
}

/// 特定日期: the date follows this instead of its day of the week.
public enum DayKind: String, Codable, Hashable { case work, off }

/// 00:00 – 00:00: the whole calendar day.
public extension ClockRange { static let allDay = ClockRange(ClockTime(0), ClockTime(0)) }

/// Pausa 时段. include = 提醒时段 (weekly + make-up dates); exclude = 免打扰 (weekly + skipped dates).
/// Active = include && !exclude: exclude always wins. Disabled = always active.
public struct PausaSchedule: Codable, Hashable {
    public var enabled: Bool
    public var include: HoursSet
    public var exclude: HoursSet
    public var days: [DateKey: DayKind] = [:]
    public init(enabled: Bool = false, include: HoursSet = HoursSet(), exclude: HoursSet = HoursSet(), days: [DateKey: DayKind] = [:]) {
        self.enabled = enabled; self.include = include; self.exclude = exclude; self.days = days
    }
    /// Convenience: include-only weekly rules.
    public init(enabled: Bool, rules: [PausaWindow]) { self.init(enabled: enabled, include: HoursSet(rules: rules)) }
    public var rules: [PausaWindow] { get { include.rules } set { include.rules = newValue } }

    // Codable, migrating v1 {enabled, rules, overrides: [DateKey: off | windows]}.
    private enum CodingKeys: String, CodingKey { case enabled, include, exclude, days, rules, overrides }
    private enum LegacyOverride: Codable { case off; case windows([ClockRange]) }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        if let inc = try c.decodeIfPresent(HoursSet.self, forKey: .include) {
            include = inc
            exclude = try c.decodeIfPresent(HoursSet.self, forKey: .exclude) ?? HoursSet()
            days = try c.decodeIfPresent([DateKey: DayKind].self, forKey: .days) ?? [:]
            // v2 dated ranges -> 特定日期 (Steve): whole-day skips become 休息; any date with custom hours becomes 上班, times dropped, no prompt.
            for k in include.dates.keys { days[k] = .work }
            for (k, r) in exclude.dates { days[k] = r == [.allDay] ? .off : .work }   // custom hours -> 上班
            include.dates = [:]; exclude.dates = [:]
            return
        }
        include = HoursSet(rules: try c.decodeIfPresent([PausaWindow].self, forKey: .rules) ?? [])
        exclude = HoursSet()
        // v1 "off" -> skip that date. v1 "custom windows" -> add them as a make-up date (the weekly
        // rules of that day are no longer replaced; v1 never shipped a UI, so nobody has these).
        for (k, o) in try c.decodeIfPresent([DateKey: LegacyOverride].self, forKey: .overrides) ?? [:] {
            switch o {
            case .off: days[k] = .off
            case .windows: days[k] = .work
            }
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled); try c.encode(include, forKey: .include); try c.encode(exclude, forKey: .exclude); try c.encode(days, forKey: .days)
    }
}

/// Disabled schedule = always active.
public func isActive(_ s: PausaSchedule, at t: Date, cal: Calendar) -> Bool {
    guard s.enabled else { return true }
    return s.include.contains(t, cal, kinds: s.days) && !s.exclude.contains(t, cal, kinds: s.days)
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
              let midnight = day.at(minutes: 0, cal) else { continue }
        if !flush(before: midnight) { return }
        for r in s.include.ranges(on: day, cal, kinds: s.days) + s.exclude.ranges(on: day, cal, kinds: s.days) {
            for (mins, plus) in [(r.start.minutes, 0), (r.end.minutes, r.crossesMidnight ? 1 : 0)] {
                guard let d = day.adding(days: plus, cal),
                      let at = d.at(minutes: mins, cal),
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
