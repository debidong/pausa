import os
import AppKit
import PausaCore

let args = CommandLine.arguments
#if PAUSA_DEV
if HeroMock.handles(args) { MainActor.assumeIsolated { HeroMock.run(args) } }
#endif   // before the AppleLanguages mirror below: the mock writes no settings
if let j = args.firstIndex(of: "--lang"), j + 1 < args.count { AppLanguage.override = AppLanguage(rawValue: args[j + 1]) }
// AppKit's own strings (About panel "Version", standard menus) follow AppleLanguages, read at launch.
// Mirror the in-app language there; .system clears it. Takes effect on the next launch.
if !args.contains("--lang") {
    let lang = Settings.shared.language
    if lang == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
    else { UserDefaults.standard.set([lang.rawValue], forKey: "AppleLanguages") }
}
#if DEBUG
if DebugCLI.handles(args) { DebugCLI.run(args) }   // never returns
if let i = args.firstIndex(of: "--render-settings"), i + 1 < args.count {
    if let j = args.firstIndex(of: "--lang"), j + 1 < args.count { AppLanguage.override = AppLanguage(rawValue: args[j + 1]) }
    if args.contains("--schedule-sample") {   // render-only sample (debug defaults domain)
        Settings.dryRun = true
        var s = Settings.defaultSchedule; s.enabled = true
        s.days[DateKey(y: 2026, m: 10, d: 11)] = .work
        s.exclude.rules = [PausaWindow(start: ClockTime(12), end: ClockTime(13, 30), weekdays: [2, 3, 4, 5, 6]),
                           PausaWindow(start: ClockTime(17, 30), end: ClockTime(18), weekdays: [6])]
        s.days[DateKey(y: 2026, m: 10, d: 1)] = .off
        Settings.shared.schedule = s
        Settings.shared.customPauseApps = [CustomPauseApp(bundleID: "com.apple.Safari"),
                                           CustomPauseApp(bundleID: "com.apple.TextEdit", mode: .running)]
    }
    if let j = args.firstIndex(of: "--theme"), j + 1 < args.count { SettingsView.themeOverride = ThemeChoice(rawValue: args[j + 1]) }
    MainActor.assumeIsolated { SettingsSnapshot.write(to: args[i + 1], pages: args.contains("--all-pages")) }
    exit(0)
}

if let i = args.firstIndex(of: "--render-settings-switch"), i + 3 < args.count,
   let a = ThemeChoice(rawValue: args[i + 2]), let b = ThemeChoice(rawValue: args[i + 3]) {
    MainActor.assumeIsolated { ThemeSwitchSnapshot.write(to: args[i + 1], from: a, to: b) }
    exit(0)
}

if let i = args.firstIndex(of: "--render-interval-menu"), i + 1 < args.count {
    if let j = args.firstIndex(of: "--lang"), j + 1 < args.count { AppLanguage.override = AppLanguage(rawValue: args[j + 1]) }
    MainActor.assumeIsolated { IntervalMenuSnapshot.write(to: args[i + 1]) }
    exit(0)
}

if let i = args.firstIndex(of: "--render-theme-picker"), i + 1 < args.count {
    MainActor.assumeIsolated { ThemePickerSnapshot.write(to: args[i + 1]) }
    exit(0)
}

if let i = args.firstIndex(of: "--render-update-ui"), i + 1 < args.count {
    MainActor.assumeIsolated { UpdateUISnapshot.write(to: args[i + 1]) }
    exit(0)
}

if let i = args.firstIndex(of: "--render-menu"), i + 1 < args.count {
    if let j = args.firstIndex(of: "--lang"), j + 1 < args.count { AppLanguage.override = AppLanguage(rawValue: args[j + 1]) }
    if let j = args.firstIndex(of: "--theme"), j + 1 < args.count { SettingsView.themeOverride = ThemeChoice(rawValue: args[j + 1]) }
    MainActor.assumeIsolated { MenuSnapshot.write(to: args[i + 1]); MenuSnapshot.writeBar(to: args[i + 1]) }
    exit(0)
}
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Dock icon click (only possible with "Show in Dock" on) opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar?.openSettings()
        return true
    }
    var controller: AppController!
    var menuBar: MenuBarController!
    let updater = Updater()
    func applicationDidFinishLaunching(_ n: Notification) {
        Settings.shared.icon.apply()
        Settings.shared.appearance.apply()
        controller = AppController()
        // Sparkle hooks: never relaunch mid-break; persist the scheduler right before relaunching.
        updater.canInstallNow = { [weak self] in !(self?.controller.isOnBreak ?? false) }
        updater.willRelaunch = { [weak self] in self?.controller.saveState() }
        controller.onBreakEnded = { [weak self] in self?.updater.breakEnded() }
        UpdateModel.shared.bind(updater)
        menuBar = MenuBarController(app: controller)
        updater.start()   // scheduled checks (SUScheduledCheckInterval); silent
        Settings.shared.enableLaunchAtLoginOnFirstRun()
        controller.start()
#if PAUSA_DEV
        pendingDevURLs.forEach(handleDevURL); pendingDevURLs = []
#endif
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        Logger(subsystem: "app.pausa", category: "update").info("launched version \(v, privacy: .public) pid \(ProcessInfo.processInfo.processIdentifier) path \(Bundle.main.bundlePath, privacy: .public)")
#if DEBUG
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--capture-menu"), i + 1 < a.count {
            menuBar.captureMenu(to: a[i + 1], paused: a.contains("--paused"), meeting: a.contains("--meeting")); return
        }
        if CommandLine.arguments.contains("--verify-lang-switch") { menuBar.verifyLanguageSwitch(); return }
#endif
        // Let the system "Login Item Added" notice pass first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.menuBar.showWelcomeOnce() }
    }
    /// pausa-dev://break?kind=short|long[&daypart=day|night|midnight]. The scheme is registered only in DEV=1 builds
    /// (App/build-app.sh) and the handler compiles only with PAUSA_DEV, so release builds contain none of it.
    /// URLs that arrive before launch finishes are queued and run once the controller exists.
    #if PAUSA_DEV   // dev-only test link: not compiled into release builds at all
    private var pendingDevURLs: [URL] = []
    private let devLog = Logger(subsystem: "app.pausa", category: "dev")
    func application(_ application: NSApplication, open urls: [URL]) {
        devLog.info("open urls \(urls.map(\.absoluteString).joined(separator: " "), privacy: .public) controller \(self.controller == nil ? "nil" : "ready", privacy: .public)")
        guard Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true else { return }
        guard controller != nil else { pendingDevURLs += urls; return }
        urls.forEach(handleDevURL)
    }
    private func handleDevURL(_ url: URL) {
        guard url.scheme == "pausa-dev", url.host == "break" else { return }
        guard !controller.isOnBreak else { devLog.info("dev url ignored: already on break"); return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let kind = items.first { $0.name == "kind" }?.value
        controller.overlay.devDaypartOverride = items.first { $0.name == "daypart" }?.value
            .flatMap(BreakDaypart.init(rawValue:))
        switch kind {
        case "short": controller.breakNow(.short)
        case "long": controller.breakNow(.long)
        default: controller.breakNow(controller.scheduler.next.kind)
        }
        devLog.info("dev url break kind \(kind ?? "next", privacy: .public)")
    }
    #endif
    func applicationWillTerminate(_ n: Notification) {
        controller?.saveState()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
