import AppKit
import CoreGraphics

/// §2 / §9 screen sharing & recording. Heuristic: macOS has no public "screen is being shared"
/// API. Uses only CGWindowList owner/bounds/layer (never titles) and the running-app list, so
/// no Screen Recording permission. All window signatures below are UNVERIFIED until captured on
/// fcBowena with the §9 commands; tune the constants then.
enum ScreenShareMonitor {
    enum Kind: Equatable { case sharing(app: NSRunningApplication), recording(app: NSRunningApplication) }
    enum Match<Owner: Equatable>: Equatable { case sharing(Owner), recording(Owner) }

    /// Instance-owned persistence state for the Chromium share bar so background detector ticks
    /// never race on unprotected global variables.
    struct Tracker: Sendable, Equatable {
        var browserBarSince: TimeInterval?

        mutating func acceptBrowserBar(seen: Bool, inMeeting: Bool, now: TimeInterval,
                                       persistence: TimeInterval = ScreenShareMonitor.barPersistence) -> Bool {
            guard seen, inMeeting else {
                browserBarSince = nil
                return false
            }
            if browserBarSince == nil { browserBarSince = now }
            return now - (browserBarSince ?? now) >= persistence
        }
    }

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

    /// §9: the browser share bar must persist this long before it counts.
    static let barPersistence: TimeInterval = 3

    private final class DefaultTrackerBox: @unchecked Sendable {
        let lock = NSLock()
        var tracker = Tracker()
    }
    private static let defaultTracker = DefaultTrackerBox()

    /// Convenience entry for one-shot debug CLI checks (`--debug-detect`).
    static func check(inMeeting: Bool, snapshot: DetectionSnapshot? = nil,
                      now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Kind? {
        defaultTracker.lock.lock()
        defer { defaultTracker.lock.unlock() }
        return check(inMeeting: inMeeting, tracker: &defaultTracker.tracker, snapshot: snapshot, now: now)
    }

    /// `inMeeting`: existing mic/camera signal (§9 ⑤), required to accept the browser-bar signal.
    static func check(inMeeting: Bool, tracker: inout Tracker, snapshot: DetectionSnapshot? = nil,
                      now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Kind? {
        let snap = snapshot ?? DetectionSnapshot()
        let list = snap.onScreenWindows
        if list.isEmpty {
            _ = tracker.acceptBrowserBar(seen: false, inMeeting: inMeeting, now: now)
            return nil
        }
        let byPID = snap.appsByPID
        let candidates: [(owner: NSRunningApplication, bundleID: String, layer: Int, bounds: CGRect)] = list.compactMap { w in
            guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber).map({ pid_t($0.int32Value) })
                    ?? (w[kCGWindowOwnerPID as String] as? pid_t),
                  let app = byPID[pid], let bid = app.bundleIdentifier,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd) else { return nil }
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue
                ?? (w[kCGWindowLayer as String] as? Int) ?? 0
            return (owner: app, bundleID: bid, layer: layer, bounds: r)
        }
        switch evaluate(windows: candidates, screens: snap.displayBounds, inMeeting: inMeeting, tracker: &tracker, now: now) {
        case .sharing(let app)?: return .sharing(app: app)
        case .recording(let app)?: return .recording(app: app)
        case nil: return nil
        }
    }

    static func evaluate<Owner: Equatable>(
        windows: [(owner: Owner, bundleID: String, layer: Int, bounds: CGRect)],
        screens: [CGRect],
        inMeeting: Bool,
        tracker: inout Tracker,
        now: TimeInterval
    ) -> Match<Owner>? {
        var barSeen: Owner?
        var result: Match<Owner>?

        for w in windows {
            let bid = w.bundleID
            let layer = w.layer
            let r = w.bounds
            let small = r.width < 700 && r.height < 120 && r.width > 40

            // Recorders: running alone is not enough; need a floating control/selection window.
            if recorderBundleIDs.contains(bid), layer > 0, small, result == nil {
                result = .recording(w.owner)
            }
            // Meeting apps put a floating share toolbar / border above normal windows while sharing.
            if meetingBundleIDs.contains(bid), layer > 0, inMeeting {
                let border = screens.contains { abs($0.width - r.width) < 8 && abs($0.height - r.height) < 8 }
                if small || border { result = .sharing(w.owner) }
            }
            // Chromium "正在共享 · 停止共享 · 隐藏" bar: small, bottom-centred, floating (§9 ①).
            if chromiumBrowsers.contains(bid), layer > 0, r.height >= 30, r.height <= 80, r.width < 700,
               let s = screens.first(where: { $0.intersects(r) }),
               abs(r.midX - s.midX) < 80, s.maxY - r.maxY < 140 {
                barSeen = w.owner
            }
        }

        if tracker.acceptBrowserBar(seen: barSeen != nil, inMeeting: inMeeting, now: now),
           let b = barSeen, result == nil {
            result = .sharing(b)
        }
        return result
    }
    // replayd is NOT a signal: it stays resident after any recording/share (false
    // "meeting" on fcBowena, 2026-10-15). The browser bar now needs mic/camera.
}
