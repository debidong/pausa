import AppKit
import IOKit.pwr_mgt
import PausaCore

/// §1 browser video. A playing <video> makes the browser (really one of its helper processes)
/// hold a PreventUserIdleDisplaySleep power assertion. We read assertions with the public
/// IOPMCopyAssertionsByProcess (same data as `pmset -g assertions`, no permission), map each
/// holder back to its browser, and require that browser to be frontmost.
/// Unverified on macOS 27: which helper holds it per browser; whether every <video> asserts.
enum BrowserVideoMonitor {
    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "company.thebrowser.Browser",            // Arc
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
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

    /// Browser whose helper holds the assertion, by pid of the browser app.
    static func browserOwning(_ pid: pid_t, apps: [NSRunningApplication]) -> NSRunningApplication? {
        let browsers = apps.filter { browserBundleIDs.contains($0.bundleIdentifier ?? "") }
        if browsers.isEmpty { return nil }
        for p in ProcessLineage.lineage(of: pid) {
            if let b = browsers.first(where: { $0.processIdentifier == p }) { return b }
        }
        // Safari's WebKit XPC services are launchd children; fall back to bundle path containment.
        if let path = ProcessLineage.path(of: pid) {
            if let outer = ProcessLineage.outerAppBundle(path),
               let b = browsers.first(where: { $0.bundleURL?.path == outer }) { return b }
            if path.contains("com.apple.WebKit"), let s = browsers.first(where: { $0.bundleIdentifier?.hasPrefix("com.apple.Safari") == true }) {
                return s   // WebKit services are shared; only counts if Safari is the frontmost below
            }
        }
        return nil
    }

    /// Name of the frontmost browser that is playing video, if any.
    static func check() -> NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              browserBundleIDs.contains(front.bundleIdentifier ?? "") else { return nil }
        let apps = NSWorkspace.shared.runningApplications
        for pid in assertingPIDs() {
            guard let b = browserOwning(pid, apps: apps), b.processIdentifier == front.processIdentifier else { continue }
            return front
        }
        return nil
    }
}
