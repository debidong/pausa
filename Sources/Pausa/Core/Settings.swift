import AppKit
import ServiceManagement
import PausaCore

/// v0.1 settings: two rhythms and launch at login. Nothing else.
/// User-facing theme choice. Colors and scenery live in Overlay/Theme (Linus).
enum ThemeChoice: String, CaseIterable, Identifiable {
    case forest, ocean, sunset, night, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .forest: return L("森林")
        case .ocean: return L("大海")
        case .sunset: return L("晚霞")
        case .night: return L("夜空")
        case .system: return L("跟随系统")
        }
    }
}

/// Icon shown in the About panel and inside the app. The Finder icon (AppIcon.icns) stays ink.
enum IconChoice: String, CaseIterable, Identifiable {
    case ink, glass
    var id: String { rawValue }
    var title: String { self == .ink ? L("水墨") : L("玻璃") }
    /// PNGs copied into Contents/Resources by App/build-app.sh; nil when run outside the .app.
    var image: NSImage? {
        guard let url = Bundle.main.url(forResource: "icon-\(rawValue)", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
    func apply() { if let img = image { NSApplication.shared.applicationIconImage = img } }
}

/// Light/dark for Pausa's own windows. Applied app-wide via NSApp.appearance; no restart.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return L("appearance.system"); case .light: return L("浅色"); case .dark: return L("深色") }
    }
    func apply() {
        NSApplication.shared.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension Notification.Name {
    static let pausaThemeChanged = Notification.Name("PausaThemeChanged")
    static let pausaLanguageChanged = Notification.Name("PausaLanguageChanged")
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard
    var onChange: ((Config) -> Void)?

    // Allowed steps (ranges reviewed by 华佗); first value of each pair is the recommended default.
    static let shortEveryOptions = [10, 15, 20, 25, 30, 40, 45, 60]      // minutes
    static let shortLengthOptions = [20, 30, 45, 60]                 // seconds
    static let longEveryOptions = [30, 40, 45, 50, 60, 90, 120]          // minutes
    static let longLengthOptions = [1, 2, 3, 5, 10]                  // minutes
    static let recommended = (shortEvery: 20, shortLength: 20, longEvery: 50, longLength: 5)

    /// Rhythm presets. Values pending medical confirmation: keep them all in this one table.
    enum Preset: String, CaseIterable, Identifiable {
        case eyes, standard, gentle, custom
        var id: String { rawValue }
        var title: String {
            switch self { case .eyes: return L("护眼优先"); case .standard: return L("标准"); case .gentle: return L("少打扰"); case .custom: return L("自定义") }
        }
        /// (short every min, short length s, long every min, long length min); nil = custom.
        var values: (shortEvery: Int, shortLength: Int, longEvery: Int, longLength: Int)? {
            switch self {
            case .eyes: return (20, 20, 45, 5)
            case .standard: return (20, 20, 50, 5)
            case .gentle: return (40, 20, 60, 5)
            case .custom: return nil
            }
        }
    }

    var preset: Preset {
        get {
            Preset.allCases.first { p in
                guard let v = p.values else { return false }
                return v.shortEvery == shortEveryMin && v.shortLength == shortLengthSec && v.longEvery == longEveryMin && v.longLength == longLengthMin
            } ?? .custom
        }
        set {
            guard let v = newValue.values else { return }
            objectWillChange.send()
            shortEveryMin = v.shortEvery; shortLengthSec = v.shortLength; longEveryMin = v.longEvery; longLengthMin = v.longLength
        }
    }

    /// Pausa 时段. Disabled by default = always active, so existing users see no change.
    @Published var schedule: PausaSchedule {
        didSet {
            if !Self.dryRun, let data = try? JSONEncoder().encode(schedule) { d.set(data, forKey: "schedule") }
            onScheduleChange?()
        }
    }
    var onScheduleChange: (() -> Void)?
    /// Render tools set this so sample data never reaches the user's defaults.
    static var dryRun = false
    static let defaultSchedule = PausaSchedule(enabled: false, rules: [
        PausaWindow(start: ClockTime(9), end: ClockTime(18), weekdays: [2, 3, 4, 5, 6])])

    @Published var shortEveryMin: Int { didSet { save() } }
    @Published var shortLengthSec: Int { didSet { save() } }
    @Published var longEveryMin: Int { didSet { save() } }
    @Published var longLengthMin: Int { didSet { save() } }
    @Published var theme: ThemeChoice {
        didSet {
            d.set(theme.rawValue, forKey: "theme")
            NotificationCenter.default.post(name: .pausaThemeChanged, object: theme)
        }
    }

    @Published var appearance: AppearanceMode {
        didSet {
            d.set(appearance.rawValue, forKey: "appearance")
            appearance.apply()
        }
    }

    @Published var icon: IconChoice {
        didSet { d.set(icon.rawValue, forKey: "icon"); icon.apply() }
    }

    /// Default off: Pausa lives in the menu bar (LSUIElement). On: also a regular Dock app.
    @Published var showInDock: Bool {
        didSet { d.set(showInDock, forKey: "showInDock") }
    }

    @Published var language: AppLanguage {
        didSet {
            d.set(language.rawValue, forKey: "language")
            NotificationCenter.default.post(name: .pausaLanguageChanged, object: language)
        }
    }

    private init() {
        let r = Self.recommended
        let ud = UserDefaults.standard
        ud.register(defaults: ["shortEveryMin": r.shortEvery, "shortLengthSec": r.shortLength,
                              "longEveryMin": r.longEvery, "longLengthMin": r.longLength])
        func pick(_ key: String, _ allowed: [Int], _ def: Int) -> Int {
            let v = ud.integer(forKey: key); return allowed.contains(v) ? v : def
        }
        shortEveryMin = pick("shortEveryMin", Self.shortEveryOptions, r.shortEvery)
        shortLengthSec = pick("shortLengthSec", Self.shortLengthOptions, r.shortLength)
        longEveryMin = pick("longEveryMin", Self.longEveryOptions, r.longEvery)
        theme = ThemeChoice(rawValue: ud.string(forKey: "theme") ?? "") ?? .forest
        showInDock = ud.bool(forKey: "showInDock")
        appearance = AppearanceMode(rawValue: ud.string(forKey: "appearance") ?? "") ?? .system
        icon = IconChoice(rawValue: ud.string(forKey: "icon") ?? "") ?? .ink
        language = AppLanguage(rawValue: ud.string(forKey: "language") ?? "") ?? .system
        longLengthMin = pick("longLengthMin", Self.longLengthOptions, r.longLength)
        schedule = ud.data(forKey: "schedule").flatMap { try? JSONDecoder().decode(PausaSchedule.self, from: $0) } ?? Self.defaultSchedule
    }

    var config: Config {
        var c = Config()
        c.shortEvery = Double(shortEveryMin) * 60
        c.longEvery = Double(longEveryMin) * 60
        c.shortLength = Double(shortLengthSec)
        c.longLength = Double(longLengthMin) * 60
        return c
    }

    private func save() {
        d.set(shortEveryMin, forKey: "shortEveryMin")
        d.set(longEveryMin, forKey: "longEveryMin")
        d.set(shortLengthSec, forKey: "shortLengthSec")
        d.set(longLengthMin, forKey: "longLengthMin")
        onChange?(config)
    }

    // Launch at login via SMAppService (macOS 13+). Only works from a real .app bundle.
    // Cached + optimistic: the UI flips immediately; register/unregister (which can block for
    // hundreds of ms) runs off the main thread, so the switch knob's slide is never stalled.
    @Published private(set) var launchAtLoginState: Bool = SMAppService.mainApp.status == .enabled
    var launchAtLogin: Bool {
        get { launchAtLoginState }
        set {
            guard newValue != launchAtLoginState else { return }
            launchAtLoginState = newValue
            DispatchQueue.global(qos: .userInitiated).async {
                do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                catch { NSLog("Pausa: launch at login failed: \(error)") }
                let actual = SMAppService.mainApp.status == .enabled
                DispatchQueue.main.async {   // singleton: strong capture is fine
                    if self.launchAtLoginState != actual { self.launchAtLoginState = actual }   // revert on failure
                }
            }
        }
    }

    /// First launch only: turn launch-at-login on by default, quietly.
    func enableLaunchAtLoginOnFirstRun() {
        guard !d.bool(forKey: "didFirstRun") else { return }
        d.set(true, forKey: "didFirstRun")
        if Bundle.main.bundleURL.pathExtension == "app" { launchAtLogin = true }
    }
}
