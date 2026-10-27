import AppKit
import IOKit.pwr_mgt
import PausaCore

/// §1 browser video. A playing <video> makes the browser (really one of its helper processes)
/// hold a "Video Wake Lock" power assertion. We read assertions with the public
/// IOPMCopyAssertionsByProcess (same data as `pmset -g assertions`, no permission), map each
/// holder back to its app, and require that app to be frontmost.
/// Unverified on macOS 27: which helper holds it per browser; whether every <video> asserts.
enum BrowserVideoMonitor {
    /// Only used to prefer a browser when naming a meeting app (PauseSource.meetingApp); not a video gate.
    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "company.thebrowser.Browser",            // Arc
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "at.studio.AsideBrowser",                 // Aside; "Video Wake Lock" from the main pid seen in pmset log 2026-10-25
    ]
    /// Pids currently holding a video-playback assertion (VideoSignal: by type and name).
    static func assertingPIDs() -> [pid_t] {
        var dictRef: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dictRef) == kIOReturnSuccess,
              let dict = dictRef?.takeRetainedValue() as? [AnyHashable: Any] else { return [] }
        var out: [pid_t] = []
        for (k, v) in dict {
            let pid: pid_t? = (k as? NSNumber).map { pid_t($0.int32Value) } ?? (k as? Int).map { pid_t($0) }
            guard let pid, let list = v as? [[String: Any]] else { continue }
            if list.contains(where: { VideoSignal.isPlayback(type: $0[kIOPMAssertionTypeKey as String] as? String,
                                                           name: $0[kIOPMAssertionNameKey as String] as? String) }) {
                out.append(pid)
            }
        }
        return out
    }

    /// True if `pid` (a helper or the app itself) belongs to `app`.
    static func pid(_ pid: pid_t, belongsTo app: NSRunningApplication) -> Bool {
        if ProcessLineage.lineage(of: pid).contains(app.processIdentifier) { return true }
        guard let path = ProcessLineage.path(of: pid) else { return false }
        if let outer = ProcessLineage.outerAppBundle(path), app.bundleURL?.path == outer { return true }
        // Safari's WebKit XPC services are launchd children, shared by every WebKit app.
        return path.contains("com.apple.WebKit") && app.bundleIdentifier?.hasPrefix("com.apple.Safari") == true
    }

    /// The frontmost app, if it is playing video: it (or a helper of it) holds a "Video Wake Lock".
    /// No browser list: any app that asks for that assertion by that name is playing a <video>
    /// (Chrome, Aside, other Chromium builds), and only the frontmost one counts.
    static func check() -> NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        return assertingPIDs().contains { pid($0, belongsTo: front) } ? front : nil
    }
}
