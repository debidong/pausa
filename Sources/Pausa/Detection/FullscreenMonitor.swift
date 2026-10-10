import AppKit
import CoreGraphics

/// Decides whether the frontmost app is fullscreen *and* is the kind of app we
/// should not interrupt (video player, game, presentation).
///
/// Rule (v0.1, deliberately simple, see PRD §6 / TECH §1.4):
///   1. Take the frontmost app.
///   2. It must be allowlisted: bundle ID in `pausingBundleIDs`, or its Info.plist
///      LSApplicationCategoryType is a games category.
///      Editors, IDEs, terminals and browsers in fullscreen do NOT pause
///      (browser video in fullscreen is a known gap for v0.1; a later version can
///      combine a PreventUserIdleDisplaySleep power assertion with this check).
///   3. One of its on-screen windows covers an entire display.
/// Reads window bounds/owner only: no Screen Recording permission needed.
enum FullscreenMonitor {
    static let pausingBundleIDs: Set<String> = [
        // video players
        "com.apple.QuickTimePlayerX", "com.colliderli.iina", "org.videolan.vlc",
        "com.firecore.infuse", "com.apple.TV", "io.mpv", "com.movist.MovistPro",
        "tv.plex.desktop", "com.netease.163music",
        // presentations
        "com.apple.iWork.Keynote", "com.microsoft.Powerpoint",
        // game launchers that run fullscreen
        "com.valvesoftware.steam",
    ]

    struct Result { let appName: String; let bundleID: String }

    /// Returns the pausing fullscreen app, or nil.
    static func check() -> Result? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bid = app.bundleIdentifier ?? ""
        guard isAllowlisted(app) else { return nil }
        guard frontmostCoversDisplay(pid: app.processIdentifier) else { return nil }
        return Result(appName: app.localizedName ?? bid, bundleID: bid)
    }

    /// Debug helper: does the frontmost app cover a display, regardless of allowlist?
    static func frontmostCoversDisplay() -> (app: String, covers: Bool, allowlisted: Bool)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return (app.localizedName ?? "?", frontmostCoversDisplay(pid: app.processIdentifier), isAllowlisted(app))
    }

    static func isAllowlisted(_ app: NSRunningApplication) -> Bool {
        if let bid = app.bundleIdentifier, pausingBundleIDs.contains(bid) { return true }
        return isGame(app)
    }

    private static var categoryCache: [String: Bool] = [:]
    private static let cacheLock = NSLock()

    static func isGame(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        let key = url.path
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let v = categoryCache[key] { return v }
        let cat = (Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String) ?? ""
        let v = cat.hasPrefix("public.app-category.") && cat.contains("games")
        categoryCache[key] = v
        return v
    }

    static func frontmostCoversDisplay(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let displays = activeDisplayBounds()
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let layer = w[kCGWindowLayer as String] as? Int, layer >= 0, layer < Int(CGWindowLevelForKey(.mainMenuWindow)),
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bd) else { continue }
            if let alpha = w[kCGWindowAlpha as String] as? Double, alpha < 0.1 { continue }
            for d in displays where rect.insetBy(dx: -1, dy: -1).contains(d) { return true }
        }
        return false
    }

    /// Display bounds in the CG global (top-left origin) space, same as window bounds.
    static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map { CGDisplayBounds($0) }
    }
}
