import Foundation

/// Time of day for a long break: day 05:00–17:59, night 18:00–22:59, midnight 23:00–04:59,
/// by the Mac's local clock. Computed once when a break starts and kept for the whole break,
/// so the quote and the screen style always agree.
public enum BreakDaypart: String, CaseIterable {
    case day, night, midnight
    public static func current(at date: Date = Date(), cal: Calendar = .autoupdatingCurrent) -> BreakDaypart {
        switch cal.component(.hour, from: date) {
        case 5..<18: return .day
        case 18..<23: return .night
        default: return .midnight
        }
    }
}

/// Break prompts loaded from Resources/rest-quotes.json (App/rest-quotes.json):
/// - Long break: 108 lines across 3 dayparts (54 day / 30 night / 24 midnight).
/// - Short break: 16 concise micro-prompts (category = "short").
/// Deduplication persists across calendar days per category: a pool never repeats an item until every
/// item in that category has been shown, and cycle wrap-around never repeats the immediately preceding item.
enum RestQuotes {
    struct Quote: Decodable {
        let id: String
        let category: String
        let text: [String: String]
        private struct K: CodingKey {
            var stringValue: String
            init?(stringValue s: String) { stringValue = s }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            id = try c.decode(String.self, forKey: K(stringValue: "id")!)
            category = try c.decode(String.self, forKey: K(stringValue: "category")!)
            var t: [String: String] = [:]
            for k in c.allKeys where !["id", "category"].contains(k.stringValue) {
                t[k.stringValue] = try c.decode(String.self, forKey: k)
            }
            text = t
        }
        func text(for lang: AppLanguage) -> String? { text[lang.rawValue] ?? text["en"] }
    }

    static let all: [Quote] = {
        let urls = [Bundle.main.url(forResource: "rest-quotes", withExtension: "json"),
                    URL(fileURLWithPath: "App/rest-quotes.json")].compactMap { $0 }   // 2nd: `swift run` from the repo
        for u in urls {
            if let d = try? Data(contentsOf: u), let q = try? JSONDecoder().decode([Quote].self, from: d) {
                return q
            }
        }
        return []
    }()

    static let longQuotes: [Quote] = all.filter { $0.category != "short" }
    static let shortPool: [Quote] = all.filter { $0.category == "short" }

    static func pool(_ part: BreakDaypart) -> [Quote] { all.filter { $0.category == part.rawValue } }

    static func usedKey(for category: String) -> String { "restQuotes.used.\(category)" }
    static func lastKey(for category: String) -> String { "restQuotes.last.\(category)" }

    private static func pick(from pool: [Quote], category: String, defaults d: UserDefaults,
                             random: (Int) -> Int) -> String? {
        guard !pool.isEmpty else { return nil }
        // Clean up legacy single-day keys if still present.
        for legacy in ["restQuotes.used", "restQuotes.day", "restQuotes.last"] where d.object(forKey: legacy) != nil {
            d.removeObject(forKey: legacy)
        }
        let uKey = usedKey(for: category)
        let lKey = lastKey(for: category)
        let validIDs = Set(pool.map(\.id))
        var used = Set(d.stringArray(forKey: uKey) ?? []).intersection(validIDs)
        let last = d.string(forKey: lKey)
        var cands = pool.filter { !used.contains($0.id) }
        if cands.isEmpty {   // full cycle exhausted across days: start a fresh cycle without repeating `last`
            used.removeAll()
            cands = pool.filter { $0.id != last }
            if cands.isEmpty { cands = pool }
        }
        let q = cands[random(cands.count)]
        used.insert(q.id)
        d.set(Array(used).sorted(), forKey: uKey)
        d.set(q.id, forKey: lKey)
        return q.text(for: AppLanguage.current)
    }

    /// Picks, records, and returns the next long-break line in the current app language (nil if no data).
    static func next(_ part: BreakDaypart, defaults d: UserDefaults = PausaDefaults.store, now: Date = Date(),
                     random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> String? {
        _ = now
        return pick(from: pool(part), category: part.rawValue, defaults: d, random: random)
    }

    /// Picks, records, and returns the next short-break micro-prompt in the current app language.
    static func nextShort(defaults d: UserDefaults = PausaDefaults.store,
                          random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> String {
        pick(from: shortPool, category: "short", defaults: d, random: random) ?? L("break.short.hint")
    }

    /// Debug renders: a fixed quote by id.
    static func text(id: String) -> String? { all.first { $0.id == id }?.text(for: AppLanguage.current) }
}
