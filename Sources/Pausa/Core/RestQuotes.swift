import Foundation

/// Time of day for a long break (Steve's spec, Oct 14): day 06:00–17:59, night 18:00–22:59,
/// midnight 23:00–05:59, by the Mac's local clock. Computed once when a break starts and kept
/// for the whole break, so the quote and the screen style always agree.
public enum BreakDaypart: String, CaseIterable {
    case day, night, midnight
    public static func current(at date: Date = Date(), cal: Calendar = .autoupdatingCurrent) -> BreakDaypart {
        switch cal.component(.hour, from: date) {
        case 6..<18: return .day
        case 18..<23: return .night
        default: return .midnight
        }
    }
}

/// The line under the long-break countdown, from Resources/rest-quotes.json (App/rest-quotes.json).
/// 12 lines per daypart (category = day/night/midnight). Short breaks show no quote, only 「看看远处」.
/// No quote repeats within one local calendar day (used ids + the day are kept in UserDefaults); if a
/// daypart runs dry that day, it starts over, never repeating the last one shown.
enum RestQuotes {
    struct Quote: Decodable { let id: String; let category: String; let text: [String: String]
        private struct K: CodingKey { var stringValue: String; init?(stringValue s: String) { stringValue = s }; var intValue: Int? { nil }; init?(intValue: Int) { nil } }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            id = try c.decode(String.self, forKey: K(stringValue: "id")!)
            category = try c.decode(String.self, forKey: K(stringValue: "category")!)
            var t: [String: String] = [:]
            for k in c.allKeys where !["id", "category"].contains(k.stringValue) { t[k.stringValue] = try c.decode(String.self, forKey: k) }
            text = t
        }
        func text(for lang: AppLanguage) -> String? { text[lang.rawValue] ?? text["en"] }
    }

    static let all: [Quote] = {
        let urls = [Bundle.main.url(forResource: "rest-quotes", withExtension: "json"),
                    URL(fileURLWithPath: "App/rest-quotes.json")].compactMap { $0 }   // 2nd: `swift run` from the repo
        for u in urls { if let d = try? Data(contentsOf: u), let q = try? JSONDecoder().decode([Quote].self, from: d) { return q } }
        return []
    }()

    static func pool(_ part: BreakDaypart) -> [Quote] { all.filter { $0.category == part.rawValue } }

    private static let usedKey = "restQuotes.used", dayKey = "restQuotes.day", lastKey = "restQuotes.last"

    static func today(_ now: Date = Date(), cal: Calendar = .autoupdatingCurrent) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Picks, records, and returns the next line in the current app language (nil if no data).
    static func next(_ part: BreakDaypart, defaults d: UserDefaults = .standard, now: Date = Date(),
                     random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> String? {
        let p = pool(part)
        guard !p.isEmpty else { return nil }
        let day = today(now)
        var used = Set(d.string(forKey: dayKey) == day ? (d.stringArray(forKey: usedKey) ?? []) : [])
        let last = d.string(forKey: lastKey)
        var cands = p.filter { !used.contains($0.id) }
        if cands.isEmpty {   // pool exhausted today: start this pool over
            used.subtract(p.map(\.id))
            cands = p.filter { $0.id != last }
            if cands.isEmpty { cands = p }
        }
        let q = cands[random(cands.count)]
        used.insert(q.id)
        d.set(day, forKey: dayKey); d.set(Array(used).sorted(), forKey: usedKey); d.set(q.id, forKey: lastKey)
        return q.text(for: AppLanguage.current)
    }

    /// Debug renders: a fixed quote by id.
    static func text(id: String) -> String? { all.first { $0.id == id }?.text(for: AppLanguage.current) }
}
