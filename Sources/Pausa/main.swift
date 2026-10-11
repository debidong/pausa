import AppKit
import PausaCore

let args = CommandLine.arguments
if let j = args.firstIndex(of: "--lang"), j + 1 < args.count { AppLanguage.override = AppLanguage(rawValue: args[j + 1]) }
// AppKit's own strings (About panel "Version", standard menus) follow AppleLanguages, read at launch.
// Mirror the in-app language there; .system clears it. Takes effect on the next launch.
if !args.contains("--lang") {
    let lang = Settings.shared.language
    if lang == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
    else { UserDefaults.standard.set([lang.rawValue], forKey: "AppleLanguages") }
}
if DebugCLI.handles(args) { DebugCLI.run(args) }   // never returns
if let i = args.firstIndex(of: "--render-settings"), i + 1 < args.count {
    if let j = args.firstIndex(of: "--lang"), j + 1 < args.count { AppLanguage.override = AppLanguage(rawValue: args[j + 1]) }
    if args.contains("--schedule-sample") {   // render-only sample (debug defaults domain)
        Settings.dryRun = true
        var s = Settings.defaultSchedule; s.enabled = true
        s.include.dates[DateKey(y: 2026, m: 10, d: 10)] = [ClockRange(ClockTime(9), ClockTime(18))]
        s.exclude.rules = [PausaWindow(start: ClockTime(12), end: ClockTime(13, 30), weekdays: [2, 3, 4, 5, 6])]
        s.exclude.dates[DateKey(y: 2026, m: 10, d: 1)] = [.allDay]
        Settings.shared.schedule = s
    }
    MainActor.assumeIsolated { SettingsSnapshot.write(to: args[i + 1], pages: args.contains("--all-pages")) }
    exit(0)
}



if let i = args.firstIndex(of: "--render-settings-switch"), i + 3 < args.count,
   let a = ThemeChoice(rawValue: args[i + 2]), let b = ThemeChoice(rawValue: args[i + 3]) {
    MainActor.assumeIsolated { ThemeSwitchSnapshot.write(to: args[i + 1], from: a, to: b) }
    exit(0)
}

if let i = args.firstIndex(of: "--render-menu"), i + 1 < args.count {
    if let j = args.firstIndex(of: "--lang"), j + 1 < args.count { AppLanguage.override = AppLanguage(rawValue: args[j + 1]) }
    MainActor.assumeIsolated { MenuSnapshot.write(to: args[i + 1]) }
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Dock icon click (only possible with "Show in Dock" on) opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar?.openSettings()
        return true
    }
    var controller: AppController!
    var menuBar: MenuBarController!
    func applicationDidFinishLaunching(_ n: Notification) {
        Settings.shared.icon.apply()
        Settings.shared.appearance.apply()
        controller = AppController()
        menuBar = MenuBarController(app: controller)
        Settings.shared.enableLaunchAtLoginOnFirstRun()
        controller.start()
        // Let the system "Login Item Added" notice pass first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.menuBar.showWelcomeOnce() }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
