import Foundation

/// Single source of truth for every `UserDefaults` key Pausa reads or writes.
/// Keeping all keys here eliminates scattered string literals across `Core/`, `MenuBar/`,
/// `Overlay/` and `Detection/`.
enum DefaultsKey {
    // Schedule & break rhythm
    static let shortEveryMin = "shortEveryMin"
    static let shortLengthSec = "shortLengthSec"
    static let shortsBeforeLong = "shortsBeforeLong"
    static let longLengthMin = "longLengthMin"
    static let hardLineMinutes = "hardLineMinutes"
    static let schedule = "schedule"

    // Legacy migration keys (removed after migration)
    static let legacyLongEveryNth = "longEveryNth"
    static let legacyLongEveryMin = "longEveryMin"
    static let legacyMenuBarStyle = "menuBarStyle"
    static let legacyBrowserVideoScope = "browserVideoScope"
    static let legacyShortCountPrefix = "shortCount."

    // Appearance, sound & shell
    static let breakSound = "breakSound"
    static let theme = "theme"
    static let randomSceneLast = "randomSceneLast"
    static let photoExtraDim = "photoExtraDim"
    static let appearance = "appearance"
    static let menuBarDisplay = "menuBarDisplay"
    static let icon = "icon"
    static let showInDock = "showInDock"
    static let language = "language"
    static let appleLanguages = "AppleLanguages"

    // Pre-break & UI state
    static let showPreBreakPanel = "showPreBreakPanel"
    static let showPreBreakPill = "showPreBreakPill"
    static let settingsTab = "settingsTab"
    static let didFirstRun = "didFirstRun"
    static let didShowWelcome = "didShowWelcome"

    // Smart auto-pause & Focus Filter
    static let pauseForMeetings = "pauseForMeetings"
    static let pauseWhileTyping = "pauseWhileTyping"
    static let pauseForBrowserVideo = "pauseForBrowserVideo"
    static let pauseForScreenSharing = "pauseForScreenSharing"
    static let pauseForCustomApps = "pauseForCustomApps"
    static let customPauseApps = "customPauseApps"
    static let pauseForFocusMode = "pauseForFocusMode"
    static let focusModeScope = "focusModeScope"
    static let focusFilterActive = "focusFilterActive"
    static let focusFilterSeen = "focusFilterSeen"

    // Runtime persistence
    static let schedulerState = "scheduler.state"
    static let manualPaused = "manualPaused"
    static let manualPausedSince = "manualPausedSince"
}

/// Routes `UserDefaults` access to `.standard` in production and to an isolated, ephemeral
/// domain whenever `Settings.dryRun` is enabled, so debug snapshots/selftests never pollute
/// the user's real preferences.
enum PausaDefaults {
    private static let lock = NSLock()
    private static var dryRunSuiteName: String?
    private static var dryRunStore: UserDefaults?

    /// Active defaults store for the current process mode (`standard` vs isolated `dryRun`).
    static var store: UserDefaults {
        guard Settings.dryRun else { return .standard }
        lock.lock()
        defer { lock.unlock() }
        if let existing = dryRunStore { return existing }
        let name = "app.getpausa.Pausa.dryrun.\(ProcessInfo.processInfo.processIdentifier)"
        let ud = UserDefaults(suiteName: name) ?? .standard
        ud.removePersistentDomain(forName: name)
        dryRunSuiteName = name
        dryRunStore = ud
        return ud
    }

    /// Resets the ephemeral dry-run domain so consecutive dry-run checks start clean.
    static func resetDryRunStore() {
        lock.lock()
        defer { lock.unlock() }
        if let name = dryRunSuiteName {
            dryRunStore?.removePersistentDomain(forName: name)
        }
        dryRunStore = nil
        dryRunSuiteName = nil
    }

    /// Creates a fresh isolated `UserDefaults` domain for deterministic unit tests.
    static func makeIsolated(tag: String = UUID().uuidString) -> (defaults: UserDefaults, suiteName: String) {
        let name = "app.getpausa.Pausa.test.\(tag)"
        let ud = UserDefaults(suiteName: name)!
        ud.removePersistentDomain(forName: name)
        return (ud, name)
    }
}
