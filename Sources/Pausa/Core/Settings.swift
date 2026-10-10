import Foundation
import ServiceManagement
import PausaCore

/// v0.1 settings: two rhythms and launch at login. Nothing else.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard
    var onChange: ((Config) -> Void)?

    @Published var shortEveryMin: Int { didSet { save() } }
    @Published var longEveryMin: Int { didSet { save() } }

    private init() {
        d.register(defaults: ["shortEveryMin": 20, "longEveryMin": 50])
        shortEveryMin = d.integer(forKey: "shortEveryMin")
        longEveryMin = d.integer(forKey: "longEveryMin")
    }

    var config: Config {
        var c = Config()
        c.shortEvery = Double(shortEveryMin) * 60
        c.longEvery = Double(longEveryMin) * 60
        return c
    }

    private func save() {
        d.set(shortEveryMin, forKey: "shortEveryMin")
        d.set(longEveryMin, forKey: "longEveryMin")
        onChange?(config)
    }

    // Launch at login via SMAppService (macOS 13+). Only works from a real .app bundle.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { NSLog("Pausa: launch at login failed: \(error)") }
            objectWillChange.send()
        }
    }

    /// First launch only: turn launch-at-login on by default, quietly.
    func enableLaunchAtLoginOnFirstRun() {
        guard !d.bool(forKey: "didFirstRun") else { return }
        d.set(true, forKey: "didFirstRun")
        if Bundle.main.bundleURL.pathExtension == "app" { launchAtLogin = true }
    }
}
