import Foundation

/// App language. `.system` follows macOS preferred languages.
/// Strings are looked up by semantic key (`L("menu.quit")`); the text itself is in App/strings.json.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zhHans = "zh-Hans", zhHant = "zh-Hant", en, es, ru, fr, vi, th
    var id: String { rawValue }

    /// Shown in the picker in its own language (system row is translated).
    var nativeName: String {
        switch self {
        case .system: return L("language.system")
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .es: return "Español"
        case .ru: return "Русский"
        case .fr: return "Français"
        case .vi: return "Tiếng Việt"
        case .th: return "ภาษาไทย"
        }
    }

    /// Debug-only override (e.g. `--render-settings out.png --lang ru`); never persisted.
    static var override: AppLanguage?

    /// The concrete language in effect right now (never `.system`).
    static var current: AppLanguage {
        let chosen = override ?? Settings.shared.language
        return chosen == .system ? fromSystem(Locale.preferredLanguages) : chosen
    }

    static func fromSystem(_ preferred: [String]) -> AppLanguage {
        for id in preferred {
            let p = id.lowercased()
            if p.hasPrefix("zh") {
                let trad = ["zh-hant", "zh-tw", "zh-hk", "zh-mo"].contains { p.hasPrefix($0) }
                return trad ? .zhHant : .zhHans
            }
            for l in [AppLanguage.en, .es, .ru, .fr, .vi, .th] where p.hasPrefix(l.rawValue) { return l }
        }
        return .en
    }

    /// For SwiftUI `.environment(\.locale, AppLanguage.current.locale)`: picks PingFang TC glyphs for zh-Hant etc.
    var locale: Locale { Locale(identifier: self == .system ? AppLanguage.current.rawValue : rawValue) }
}

/// The name the app shows for itself. The dev build (App/build-app.sh DEV=1) says "Pausa Dev" where
/// the app names itself (menu bar, window titles, About, Quit), so it can't be mistaken for the
/// installed Pausa running next to it. Sentences keep 「Pausa」, so screenshots match the release.
#if PAUSA_DEV
let appName = "Pausa Dev"
#else
let appName = "Pausa"
#endif

/// The text for `key` (e.g. "stats.footnote") in the current language. Missing language -> zh-Hans,
/// missing key -> the key itself (logged in debug builds; scripts/check-strings.py catches it first).
func L(_ key: String, _ args: CVarArg...) -> String {
    let lang = AppLanguage.current
    #if DEBUG
    if L10nTables.zhHans[key] == nil { NSLog("Pausa: no string for key %@", key) }
    #endif
    let fmt = L10nTables.all[lang]?[key] ?? L10nTables.zhHans[key] ?? key
    return args.isEmpty ? fmt : String(format: fmt, locale: lang.locale, arguments: args)
}

/// CLDR cardinal plural categories for the 8 app languages (what a stringsdict would pick).
/// Keys: "key.one" / ".few" / ".many" / ".other"; missing categories fall back to ".other".
enum Plural {
    static func category(_ n: Int, _ lang: AppLanguage) -> String {
        switch lang {
        case .en, .es: return n == 1 ? "one" : "other"
        case .fr: return n == 0 || n == 1 ? "one" : "other"
        case .ru:
            let m10 = n % 10, m100 = n % 100
            if m10 == 1 && m100 != 11 { return "one" }
            if (2...4).contains(m10) && !(12...14).contains(m100) { return "few" }
            return "many"
        default: return "other"   // zh-Hans, zh-Hant, vi, th: no plural forms
        }
    }
    static func pick(_ key: String, _ n: Int) -> String {
        let lang = AppLanguage.current
        let table = L10nTables.all[lang] ?? [:]
        return table["\(key).\(category(n, lang))"] ?? table["\(key).other"]
            ?? L10nTables.zhHans["\(key).other"] ?? key
    }
}

/// Every UI string lives in App/strings.json (copied into Resources by App/build-app.sh):
/// `{ "<page>.<name>": { "zh-Hans": "...", "zh-Hant": "...", "en": "...", ... } }`, keys sorted, so a
/// page's strings sit together. Code calls L("<key>"); edit the copy in the JSON, not here.
/// Plurals: "<key>.one" / ".few" / ".many" / ".other" (see `Plural`). scripts/check-strings.py checks
/// that every key has all 8 languages, format specifiers match, and no key is unused or missing.
enum L10nTables {
    static let all: [AppLanguage: [String: String]] = {
        let urls = [Bundle.main.url(forResource: "strings", withExtension: "json"),
                    URL(fileURLWithPath: "App/strings.json")].compactMap { $0 }   // 2nd: `swift run` from the repo
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let rows = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { continue }
            var tables: [AppLanguage: [String: String]] = [:]
            for (key, row) in rows {
                for (lang, text) in row {
                    if let l = AppLanguage(rawValue: lang) { tables[l, default: [:]][key] = text }
                }
            }
            return tables
        }
        NSLog("Pausa: strings.json not found, showing source strings")
        return [:]
    }()
    static let zhHans = all[.zhHans] ?? [:]
}
