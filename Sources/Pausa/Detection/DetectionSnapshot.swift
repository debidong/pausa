import AppKit
import CoreGraphics

/// Per-tick cache of expensive cross-process queries (`CGWindowListCopyWindowInfo`,
/// `CGGetActiveDisplayList`, `NSWorkspace.shared.runningApplications` and `frontmostApplication`).
/// Instantiated once at the top of `PauseDetector.tick()` so monitors share a single snapshot
/// instead of querying WindowServer and LaunchServices 2–3 times per second.
final class DetectionSnapshot {
    private var cachedFrontmost: NSRunningApplication??
    private var cachedRunningApps: [NSRunningApplication]?
    private var cachedAppsByPID: [pid_t: NSRunningApplication]?
    private var cachedWindows: [[String: Any]]?
    private var cachedDisplays: [CGRect]?

    var frontmostApp: NSRunningApplication? {
        if let f = cachedFrontmost { return f }
        let app = NSWorkspace.shared.frontmostApplication
        cachedFrontmost = .some(app)
        return app
    }

    var runningApps: [NSRunningApplication] {
        if let apps = cachedRunningApps { return apps }
        let apps = NSWorkspace.shared.runningApplications
        cachedRunningApps = apps
        return apps
    }

    var appsByPID: [pid_t: NSRunningApplication] {
        if let map = cachedAppsByPID { return map }
        let map = Dictionary(runningApps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        cachedAppsByPID = map
        return map
    }

    var onScreenWindows: [[String: Any]] {
        if let list = cachedWindows { return list }
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        cachedWindows = list
        return list
    }

    var displayBounds: [CGRect] {
        if let bounds = cachedDisplays { return bounds }
        let bounds = FullscreenMonitor.activeDisplayBounds()
        cachedDisplays = bounds
        return bounds
    }
}
