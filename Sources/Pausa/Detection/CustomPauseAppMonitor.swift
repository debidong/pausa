import AppKit

/// §3 custom focus apps (设置 → 使用这些应用时). Settings stores [CustomPauseApp] as JSON under
/// "customPauseApps". Modes: foreground+fullscreen (default) / foreground / running.
/// Zero permission: frontmostApplication, runningApplications, CGWindowList bounds.
enum CustomPauseAppMonitor {
    private final class DecodedCache: @unchecked Sendable {
        let lock = NSLock()
        var lastData: Data?
        var apps: [CustomPauseApp] = []
    }

    private static let cache = DecodedCache()

    static func load(defaults ud: UserDefaults = PausaDefaults.store) -> [CustomPauseApp] {
        guard let d = ud.data(forKey: DefaultsKey.customPauseApps) else { return [] }
        cache.lock.lock()
        if cache.lastData == d {
            let hit = cache.apps
            cache.lock.unlock()
            return hit
        }
        cache.lock.unlock()

        let decoded = (try? JSONDecoder().decode([CustomPauseApp].self, from: d)) ?? []
        cache.lock.lock()
        cache.lastData = d
        cache.apps = decoded
        cache.lock.unlock()
        return decoded
    }

    /// Display name of the first listed app whose mode condition holds, else nil.
    static func check(snapshot: DetectionSnapshot? = nil, defaults ud: UserDefaults = PausaDefaults.store) -> String? {
        if ud.object(forKey: DefaultsKey.pauseForCustomApps) as? Bool == false { return nil }
        let list = load(defaults: ud)
        if list.isEmpty { return nil }
        let snap = snapshot ?? DetectionSnapshot()
        let front = snap.frontmostApp
        for e in list {
            switch e.mode {
            case .foregroundFullscreen:
                if let f = front, f.bundleIdentifier == e.bundleID,
                   FullscreenMonitor.frontmostCoversDisplay(pid: f.processIdentifier, snapshot: snap) {
                    return f.localizedName ?? e.bundleID
                }
            case .foreground:
                if let f = front, f.bundleIdentifier == e.bundleID { return f.localizedName ?? e.bundleID }
            case .running:
                if let a = snap.runningApps.first(where: { $0.bundleIdentifier == e.bundleID }) {
                    return a.localizedName ?? e.bundleID
                }
            }
        }
        return nil
    }
}
