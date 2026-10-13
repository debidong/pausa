import AppKit

/// §3 custom focus apps (设置 → 使用这些应用时). Settings stores [CustomPauseApp] as JSON under
/// "customPauseApps". Modes: foreground+fullscreen (default) / foreground / running.
/// Zero permission: frontmostApplication, runningApplications, CGWindowList bounds.
enum CustomPauseAppMonitor {
    static func load() -> [CustomPauseApp] {
        guard let d = UserDefaults.standard.data(forKey: "customPauseApps"),
              let list = try? JSONDecoder().decode([CustomPauseApp].self, from: d) else { return [] }
        return list
    }

    /// Display name of the first listed app whose mode condition holds, else nil.
    static func check() -> String? {
        if UserDefaults.standard.object(forKey: "pauseForCustomApps") as? Bool == false { return nil }
        let list = load()
        if list.isEmpty { return nil }
        let front = NSWorkspace.shared.frontmostApplication
        let running = NSWorkspace.shared.runningApplications
        for e in list {
            switch e.mode {
            case .foregroundFullscreen:
                if let f = front, f.bundleIdentifier == e.bundleID,
                   FullscreenMonitor.frontmostCoversDisplay(pid: f.processIdentifier) { return f.localizedName ?? e.bundleID }
            case .foreground:
                if let f = front, f.bundleIdentifier == e.bundleID { return f.localizedName ?? e.bundleID }
            case .running:
                if let a = running.first(where: { $0.bundleIdentifier == e.bundleID }) { return a.localizedName ?? e.bundleID }
            }
        }
        return nil
    }
}
