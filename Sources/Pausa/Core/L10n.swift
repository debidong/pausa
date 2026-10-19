import Foundation

/// App language. `.system` follows macOS preferred languages.
/// Strings are keyed by their Simplified Chinese source text; the text itself is in App/strings.json.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zhHans = "zh-Hans", zhHant = "zh-Hant", en, es, ru, fr, vi, th
    var id: String { rawValue }

    /// Shown in the picker in its own language (system row is translated).
    var nativeName: String {
        switch self {
        case .system: return L("跟随系统")
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

/// Translate a Simplified Chinese source string. Missing key -> the source itself.
func L(_ key: String, _ args: CVarArg...) -> String {
    let lang = AppLanguage.current
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

/// Health footnote (wording pending medical review). Change the source here; translations key off it.
enum HealthNote {
    static let key = "若眼部持续不适，请及时就医。Pausa 不能替代专业的治疗。"
}

/// Every UI string lives in App/strings.json (copied into Resources by App/build-app.sh):
/// `{ "<Simplified Chinese source>": { "zh-Hans": "...", "en": "...", ... } }`.
/// Code calls L("<source>"); edit the copy in the JSON, not here. A missing language falls
/// back to zh-Hans, then to the source text itself.
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
