import AppKit
import ServiceManagement
import PausaCore

/// v0.1 settings: two rhythms and launch at login. Nothing else.
/// User-facing theme choice. Colors and scenery live in Overlay/Theme (Linus).
/// Smart pause: when a user-listed app defers breaks.
enum CustomPauseMode: String, Codable, CaseIterable, Identifiable {
    case foregroundFullscreen   // 前台且全屏 (default)
    case foreground             // 前台时
    case running                // 打开时
    var id: String { rawValue }
}

/// One entry of the 使用这些应用时 list. Stored as JSON under "customPauseApps".
struct CustomPauseApp: Codable, Hashable, Identifiable {
    var bundleID: String
    var mode: CustomPauseMode = .foregroundFullscreen
    var id: String { bundleID }
}

/// Icon shown in the Dock, About page and inside the app (round 4, restored in 7b). Set with
/// NSApp.applicationIconImage at every launch, so the bundle and its signature never change; the
/// Finder icon (AppIcon.icns) stays the default lotus.
enum IconChoice: String, CaseIterable, Identifiable {
    case ink, glass
    var id: String { rawValue }
    var title: String { self == .ink ? L("icon.ink") : L("icon.glass") }
    /// PNGs copied into Contents/Resources by App/build-app.sh; nil when run outside the .app.
    var image: NSImage? {
        guard let url = Bundle.main.url(forResource: "icon-\(rawValue)", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
    func apply() { if let img = image { NSApplication.shared.applicationIconImage = img } }
}

/// §5: what an active macOS Focus does. No "off" here; pauseForFocusMode is the switch.
enum FocusModeScope: String, CaseIterable, Identifiable {
    case shortOnly   // 只暂停短休息 (default, Bowen)
    case all         // 也推迟长休息
    var id: String { rawValue }
}


/// 菜单栏显示 (Steve): the original 进度圆环 (default, dashed when paused) or 剩余时间 text such as 4:36.
enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case progressRing, timeLeft
    var id: String { rawValue }
    var title: String { self == .timeLeft ? L("menuBarStyle.timeLeft") : L("menuBarStyle.ring") }
}

enum ThemeChoice: String, CaseIterable, Identifiable {
    case forest, ocean, sunset, night, random, systemWallpaper, softDesktop, photo
    var id: String { rawValue }
    /// The four break scenes; 随机 picks one of these per break (never 系统壁纸, 模糊桌面 or 我的照片…).
    static let scenes: [ThemeChoice] = [.forest, .ocean, .sunset, .night]
    /// Stored values from older versions. 跟随系统 ("system") was removed: those users get 随机.
    /// Fresh installs (`raw == nil`) default to 系统壁纸 when accessible without a TCC prompt, else 随机.
    static func migrated(_ raw: String?, systemWallpaperSafe: Bool = true) -> ThemeChoice {
        guard let raw else { return systemWallpaperSafe ? .systemWallpaper : .random }
        if raw == "system" { return .random }
        return ThemeChoice(rawValue: raw) ?? .random
    }
    var title: String {
        switch self {
        case .forest: return L("theme.forest")
        case .ocean: return L("theme.ocean")
        case .sunset: return L("theme.sunset")
        case .night: return L("theme.night")
        case .random: return L("theme.random")
        case .systemWallpaper: return L("theme.systemWallpaper")
        case .softDesktop: return L("theme.softDesktop")
        case .photo: return L("theme.photo")
        }
    }
}

/// 提示音 (BreakSound lives in PausaCore with the chime rule): menu titles.
extension BreakSound {
    var title: String {
        switch self { case .off: return L("breaks.sound.off"); case .longOnly: return L("breaks.sound.longOnly"); case .all: return L("breaks.sound.all") }
    }
}

/// Light/dark for Pausa's own windows. Applied app-wide via NSApp.appearance; no restart.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return L("appearance.system"); case .light: return L("appearance.light"); case .dark: return L("appearance.dark") }
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
    private let injectedDefaults: UserDefaults?
    private var d: UserDefaults { injectedDefaults ?? PausaDefaults.store }
    private var isIsolated: Bool { injectedDefaults != nil || Self.dryRun }
    var onChange: ((Config) -> Void)?

    // Allowed steps (ranges reviewed by 华佗); first value of each pair is the recommended default.
    static let shortEveryOptions = [10, 15, 20, 25, 30, 40, 45, 60]      // minutes
    static let shortLengthOptions = [20, 30, 45, 60]                 // seconds
    static let shortsBeforeLongOptions = [1, 2, 3, 4, 5]                   // short breaks before a long one (old N − 1); interval × (count+1) ≤ hard line
    static let longLengthOptions = [1, 2, 3, 5, 10]                  // minutes
    static let recommended = (shortEvery: 20, shortLength: 20, longEvery: 60, longLength: 5)
    static let recommendedCount = 1   // Steve: default 1 short break, then a long one
    /// count if Config.allows it for this interval, otherwise the largest option it allows (never below 1).
    static func clampedCount(_ n: Int, everyMin: Int, line: Int) -> Int {
        if shortsBeforeLongOptions.contains(n), Config.allows(everyMin: everyMin, count: n, line: line) { return n }
        return shortsBeforeLongOptions.filter { Config.allows(everyMin: everyMin, count: $0, line: line) }.max() ?? shortsBeforeLongOptions[0]
    }
    /// An interval is offered only if even the smallest count keeps the long break within the hard line.
    static func intervalAllowed(_ m: Int, line: Int) -> Bool { Config.allows(everyMin: m, count: shortsBeforeLongOptions[0], line: line) }

    /// Rhythm presets. Values pending medical confirmation: keep them all in this one table.
    enum Preset: String, CaseIterable, Identifiable {
        case eyes, standard, gentle, custom
        var id: String { rawValue }
        var title: String {
            switch self { case .eyes: return L("preset.eyes"); case .standard: return L("preset.standard"); case .gentle: return L("preset.gentle"); case .custom: return L("preset.custom") }
        }
        /// (break every min, short length s, short breaks before a long one, long length min); nil = custom.
        var values: (shortEvery: Int, shortLength: Int, count: Int, longLength: Int)? {
            switch self {
            case .eyes: return (20, 20, 1, 5)
            case .standard: return (20, 20, 2, 5)
            case .gentle: return (40, 20, 1, 5)
            case .custom: return nil
            }
        }
    }

    var preset: Preset {
        get {
            Preset.allCases.first { p in
                guard let v = p.values else { return false }
                return v.shortEvery == shortEveryMin && v.shortLength == shortLengthSec && v.count == shortsBeforeLong && v.longLength == longLengthMin
            } ?? .custom
        }
        set {
            guard let v = newValue.values else { return }
            objectWillChange.send()
            shortEveryMin = v.shortEvery; shortLengthSec = v.shortLength; shortsBeforeLong = v.count; longLengthMin = v.longLength
        }
    }

    /// Pausa 时段. Disabled by default = always active, so existing users see no change.
    @Published var schedule: PausaSchedule {
        didSet {
            if let data = try? JSONEncoder().encode(schedule) { d.set(data, forKey: DefaultsKey.schedule) }
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
    @Published var shortsBeforeLong: Int { didSet { save() } }
    var longEveryNth: Int { Config.nth(fromCount: shortsBeforeLong) }
    /// 「长休息最晚间隔」: the hard line in minutes (Config.hardLineOptions). The one value every cap reads.
    @Published var hardLineMinutes: Int { didSet { save() } }
    /// 「已连续使用 N 分钟，长休息不能再延后。」 with the current hard line.
    var hardLineText: String { L("break.hardLine", hardLineMinutes) }
    /// A preset is offered only if its rhythm fits under the current hard line (greyed otherwise).
    func allows(_ p: Preset) -> Bool {
        guard let v = p.values else { return true }
        return Config.allows(everyMin: v.shortEvery, count: v.count, line: hardLineMinutes)
    }
    @Published var longLengthMin: Int { didSet { save() } }
    @Published var breakSound: BreakSound { didSet { d.set(breakSound.rawValue, forKey: DefaultsKey.breakSound) } }
    @Published var theme: ThemeChoice {
        didSet {
            d.set(theme.rawValue, forKey: DefaultsKey.theme)
            NotificationCenter.default.post(name: .pausaThemeChanged, object: theme)
        }
    }


    /// 自动暂停 → 使用指定应用时 switch; the app list stays, only the condition turns off.
    @Published var pauseForCustomApps: Bool { didSet { d.set(pauseForCustomApps, forKey: DefaultsKey.pauseForCustomApps) } }

    @Published var appearance: AppearanceMode {
        didSet {
            d.set(appearance.rawValue, forKey: DefaultsKey.appearance)
            if !isIsolated { appearance.apply() }
        }
    }


    /// Default off: Pausa lives in the menu bar (LSUIElement). On: also a regular Dock app.
    @Published var menuBarDisplay: MenuBarDisplay { didSet { d.set(menuBarDisplay.rawValue, forKey: DefaultsKey.menuBarDisplay) } }
    @Published var icon: IconChoice {
        didSet {
            d.set(icon.rawValue, forKey: DefaultsKey.icon)
            if !isIsolated { icon.apply() }
        }
    }
    @Published var showInDock: Bool {
        didSet { d.set(showInDock, forKey: DefaultsKey.showInDock) }
    }

    @Published var language: AppLanguage {
        didSet {
            d.set(language.rawValue, forKey: DefaultsKey.language)
            NotificationCenter.default.post(name: .pausaLanguageChanged, object: language)
        }
    }

    // MARK: Smart pause v2 (自动暂停). Read by the detectors / scheduler; all UserDefaults-backed.
    @Published var pauseForMeetings: Bool { didSet { d.set(pauseForMeetings, forKey: DefaultsKey.pauseForMeetings) } }
    @Published var pauseWhileTyping: Bool { didSet { d.set(pauseWhileTyping, forKey: DefaultsKey.pauseWhileTyping) } }
    @Published var pauseForBrowserVideo: Bool { didSet { d.set(pauseForBrowserVideo, forKey: DefaultsKey.pauseForBrowserVideo) } }
    @Published var pauseForScreenSharing: Bool { didSet { d.set(pauseForScreenSharing, forKey: DefaultsKey.pauseForScreenSharing) } }
    @Published var pauseForFocusMode: Bool { didSet { d.set(pauseForFocusMode, forKey: DefaultsKey.pauseForFocusMode) } }
    @Published var focusModeScope: FocusModeScope { didSet { d.set(focusModeScope.rawValue, forKey: DefaultsKey.focusModeScope) } }
    /// 休息前提醒: the top-of-screen panel and the pointer countdown are two independent switches (default on).
    @Published var showPreBreakPanel: Bool { didSet { d.set(showPreBreakPanel, forKey: DefaultsKey.showPreBreakPanel) } }
    @Published var showPreBreakPill: Bool { didSet { d.set(showPreBreakPill, forKey: DefaultsKey.showPreBreakPill) } }
    @Published var customPauseApps: [CustomPauseApp] {
        didSet { if let data = try? JSONEncoder().encode(customPauseApps) { d.set(data, forKey: DefaultsKey.customPauseApps) } }
    }

    init(defaults: UserDefaults? = nil) {
        self.injectedDefaults = defaults
        let r = Self.recommended
        let ud = defaults ?? PausaDefaults.store
        ud.register(defaults: [DefaultsKey.shortEveryMin: r.shortEvery, DefaultsKey.shortLengthSec: r.shortLength,
                               DefaultsKey.longLengthMin: r.longLength,
                               DefaultsKey.pauseForMeetings: true, DefaultsKey.pauseWhileTyping: true, DefaultsKey.pauseForBrowserVideo: true,
                               DefaultsKey.pauseForScreenSharing: true, DefaultsKey.pauseForFocusMode: true,
                               DefaultsKey.showPreBreakPanel: true, DefaultsKey.showPreBreakPill: true])
        func pick(_ key: String, _ allowed: [Int], _ def: Int) -> Int {
            let v = ud.integer(forKey: key); return allowed.contains(v) ? v : def
        }
        shortLengthSec = pick(DefaultsKey.shortLengthSec, Self.shortLengthOptions, r.shortLength)
        let line = Config.hardLineMinutes(ud.integer(forKey: DefaultsKey.hardLineMinutes))   // missing or unknown → 90
        hardLineMinutes = line
        // Migration: old builds stored "long break every M minutes"; map it to the nearest N.
        var every = pick(DefaultsKey.shortEveryMin, Self.shortEveryOptions, r.shortEvery)
        var count: Int
        if !Self.intervalAllowed(every, line: line) {   // no count ≥ 1 fits (that interval is greyed too)
            every = Self.shortEveryOptions.filter { Self.intervalAllowed($0, line: line) }.max() ?? r.shortEvery
        }
        var migratedLegacyRhythm = false
        if ud.object(forKey: DefaultsKey.shortsBeforeLong) != nil {
            count = ud.integer(forKey: DefaultsKey.shortsBeforeLong)
        } else if ud.object(forKey: DefaultsKey.legacyLongEveryNth) != nil {
            count = Config.count(fromNth: ud.integer(forKey: DefaultsKey.legacyLongEveryNth))   // N=2→1, N=3→2, …
            migratedLegacyRhythm = true
        } else if ud.object(forKey: DefaultsKey.legacyLongEveryMin) != nil {
            count = Config.count(fromNth: Config.nth(forLegacyLongEveryMin: ud.integer(forKey: DefaultsKey.legacyLongEveryMin), everyMin: every, line: line))
            migratedLegacyRhythm = true
        } else {
            count = Self.recommendedCount
        }
        ud.removeObject(forKey: DefaultsKey.legacyLongEveryNth)
        ud.removeObject(forKey: DefaultsKey.legacyLongEveryMin)
        // Clamp exactly as the interval picker does (largest count Config.allows), silently.
        count = Self.clampedCount(count, everyMin: every, line: line)
        if migratedLegacyRhythm {
            ud.set(count, forKey: DefaultsKey.shortsBeforeLong)
        }
        shortEveryMin = every
        shortsBeforeLong = count
        let isolated = defaults != nil || Self.dryRun
        let rawTheme = ud.string(forKey: DefaultsKey.theme)
        let wallpaperSafe: Bool = {
            if rawTheme != nil { return true }
            if SystemWallpaper.probeOverride != nil || !isolated {
                return SystemWallpaper.canDefaultWithoutPermissionPrompt(defaults: ud)
            }
            return true
        }()
        let initialTheme = ThemeChoice.migrated(rawTheme, systemWallpaperSafe: wallpaperSafe)
        theme = initialTheme
        if rawTheme == nil && (!isolated || SystemWallpaper.probeOverride != nil) {
            ud.set(initialTheme.rawValue, forKey: DefaultsKey.theme)
        }
        if initialTheme == .systemWallpaper && !isolated {
            SystemWallpaper.prewarmInBackground()
        }
        showInDock = ud.bool(forKey: DefaultsKey.showInDock)
        menuBarDisplay = MenuBarDisplay(rawValue: ud.string(forKey: DefaultsKey.menuBarDisplay) ?? "") ?? .progressRing   // saved choices are kept; fresh installs get the ring
        appearance = AppearanceMode(rawValue: ud.string(forKey: DefaultsKey.appearance) ?? "") ?? .system
        ud.removeObject(forKey: DefaultsKey.legacyMenuBarStyle)   // setting removed (Steve): the menu bar is clock only
        pauseForCustomApps = ud.object(forKey: DefaultsKey.pauseForCustomApps) as? Bool ?? true
        icon = IconChoice(rawValue: ud.string(forKey: DefaultsKey.icon) ?? "") ?? .ink   // round 4 default; saved choice kept
        language = AppLanguage(rawValue: ud.string(forKey: DefaultsKey.language) ?? "") ?? .system
        longLengthMin = pick(DefaultsKey.longLengthMin, Self.longLengthOptions, r.longLength)
        breakSound = BreakSound(rawValue: ud.string(forKey: DefaultsKey.breakSound) ?? "") ?? .longOnly   // default 仅长休息
        pauseForMeetings = ud.bool(forKey: DefaultsKey.pauseForMeetings)
        pauseWhileTyping = ud.bool(forKey: DefaultsKey.pauseWhileTyping)
        pauseForBrowserVideo = ud.bool(forKey: DefaultsKey.pauseForBrowserVideo)
        ud.removeObject(forKey: DefaultsKey.legacyBrowserVideoScope)   // 包括网页里的视频 removed (Steve): web video always counts
        pauseForScreenSharing = ud.bool(forKey: DefaultsKey.pauseForScreenSharing)
        pauseForFocusMode = ud.bool(forKey: DefaultsKey.pauseForFocusMode)
        showPreBreakPanel = ud.bool(forKey: DefaultsKey.showPreBreakPanel)
        showPreBreakPill = ud.bool(forKey: DefaultsKey.showPreBreakPill)
        focusModeScope = FocusModeScope(rawValue: ud.string(forKey: DefaultsKey.focusModeScope) ?? "") ?? .shortOnly
        customPauseApps = ud.data(forKey: DefaultsKey.customPauseApps).flatMap { try? JSONDecoder().decode([CustomPauseApp].self, from: $0) } ?? []
        var sch = ud.data(forKey: DefaultsKey.schedule).flatMap { try? JSONDecoder().decode(PausaSchedule.self, from: $0) } ?? Self.defaultSchedule
        // The per-range switch is gone (Steve). A range it had turned off was inactive; drop it so
        // nothing listed is silently ignored and behaviour stays the same.
        sch.include.rules.removeAll { !$0.enabled }
        sch.exclude.rules.removeAll { !$0.enabled }
        schedule = sch
    }

    var config: Config {
        var c = Config()
        c.shortEvery = Double(shortEveryMin) * 60
        c.longEveryNth = longEveryNth
        c.shortLength = Double(shortLengthSec)
        c.longLength = Double(longLengthMin) * 60
        c.hardLine = Double(hardLineMinutes) * 60
        return c
    }

    private func save() {
        d.set(shortEveryMin, forKey: DefaultsKey.shortEveryMin)
        d.set(shortsBeforeLong, forKey: DefaultsKey.shortsBeforeLong)
        d.set(shortLengthSec, forKey: DefaultsKey.shortLengthSec)
        d.set(longLengthMin, forKey: DefaultsKey.longLengthMin)
        d.set(hardLineMinutes, forKey: DefaultsKey.hardLineMinutes)
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
            guard !isIsolated else { return }
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
        guard !isIsolated, !d.bool(forKey: DefaultsKey.didFirstRun) else { return }
        d.set(true, forKey: DefaultsKey.didFirstRun)
        if Bundle.main.bundleURL.pathExtension == "app" { launchAtLogin = true }
    }
}
