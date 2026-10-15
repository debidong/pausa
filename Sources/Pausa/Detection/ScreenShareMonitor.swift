import AppKit
import CoreGraphics

/// §2 / §9 screen sharing & recording. Heuristic: macOS has no public "screen is being shared"
/// API. Uses only CGWindowList owner/bounds/layer (never titles) and the running-app list, so
/// no Screen Recording permission. All window signatures below are UNVERIFIED until captured on
/// fcBowena with the §9 commands; tune the constants then.
enum ScreenShareMonitor {
    enum Kind: Equatable { case sharing(app: NSRunningApplication), recording(app: NSRunningApplication) }

    static let recorderBundleIDs: Set<String> = [
        "com.obsproject.obs-studio", "pl.maketheweb.cleanshotx", "com.loom.desktop",
        "net.telestream.screenflow10", "net.telestream.screenflow11", "com.wulkano.kap",
        "com.apple.QuickTimePlayerX",
    ]
    static let meetingBundleIDs: Set<String> = [
        "us.zoom.xos", "com.tencent.meeting", "com.tencent.tencentmeeting", "com.electron.lark",
        "com.bytedance.lark", "com.microsoft.teams2", "com.microsoft.teams",
    ]
    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser",
    ]

    private static var browserBarSince: TimeInterval?
    /// §9: the browser share bar must persist this long before it counts.
    static var barPersistence: TimeInterval = 3

    /// `inMeeting`: existing mic/camera signal (§9 ⑤), required to accept the browser-bar signal.
    static func check(inMeeting: Bool) -> Kind? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let apps = NSWorkspace.shared.runningApplications
        let byPID = Dictionary(apps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        let screens = FullscreenMonitor.activeDisplayBounds()
        var barSeen: NSRunningApplication?
        var result: Kind?

        for w in list {
            guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber).map({ pid_t($0.int32Value) }),
                  let app = byPID[pid], let bid = app.bundleIdentifier,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd) else { continue }
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let small = r.width < 700 && r.height < 120 && r.width > 40

            // Recorders: running alone is not enough; need a floating control/selection window.
            if recorderBundleIDs.contains(bid), layer > 0, small, result == nil {
                result = .recording(app: app)
            }
            // Meeting apps put a floating share toolbar / border above normal windows while sharing.
            if meetingBundleIDs.contains(bid), layer > 0, inMeeting {
                let border = screens.contains { abs($0.width - r.width) < 8 && abs($0.height - r.height) < 8 }
                if small || border { result = .sharing(app: app) }
            }
            // Chromium "正在共享 · 停止共享 · 隐藏" bar: small, bottom-centred, floating (§9 ①).
            if chromiumBrowsers.contains(bid), layer > 0, r.height >= 30, r.height <= 80, r.width < 700,
               let s = screens.first(where: { $0.intersects(r) }),
               abs(r.midX - s.midX) < 80, s.maxY - r.maxY < 140 {
                barSeen = app
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        if let b = barSeen, inMeeting {
            if browserBarSince == nil { browserBarSince = now }
            if now - (browserBarSince ?? now) >= barPersistence, result == nil { result = .sharing(app: b) }
        } else { browserBarSince = nil }
        return result
    }
    // replayd is NOT a signal: it stays resident after any recording/share (false
    // "meeting" on fcBowena, 2026-10-15). The browser bar now needs mic/camera.
}
