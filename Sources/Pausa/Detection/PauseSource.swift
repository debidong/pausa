import AppKit
import Carbon
import CoreAudio
import PausaCore

/// What is holding a pause, for the menu status line (Mitchell draws icon + text).
/// `appName` / `bundleID` are nil when Pausa can't tell which app it is: then no icon and no
/// app line. Icon: `NSWorkspace.shared.icon(forFile:)` on
/// `NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)`.
/// `website` is for meetings in a browser (e.g. "Google Meet"); nil when not determinable
/// (today always nil: reading tab URLs/titles would need Automation or Screen Recording).
public struct PauseSource: Hashable {
    public enum Kind: Hashable { case meeting, screenSharing, video, fullscreen }
    public var kind: Kind
    public var appName: String?
    public var bundleID: String?
    public var website: String?

    public init(kind: Kind, appName: String? = nil, bundleID: String? = nil, website: String? = nil) {
        self.kind = kind; self.appName = appName; self.bundleID = bundleID; self.website = website
    }

    init(kind: Kind, app: NSRunningApplication?) {
        self.init(kind: kind, appName: app?.localizedName, bundleID: app?.bundleIdentifier)
    }

    /// Name on the app line: website for browser meetings, else app name.
    public var displayName: String? { website ?? appName }

    public var core: PausaCore.PauseReason {
        switch kind {
        case .meeting: return .meeting
        case .screenSharing: return .screenSharing
        case .video: return .video
        case .fullscreen: return .fullscreen
        }
    }

    /// Line 1 of the status: the reason only, 「暂停中：正在开会」 / "Paused: in a meeting".
    /// The app (icon + `displayName`) is line 2, drawn by the popover; no parenthesis.
    public var statusText: String {
        let base: String
        switch kind {
        case .meeting: base = "暂停中：正在开会"
        case .screenSharing: base = "暂停中：正在共享屏幕"
        case .video: base = "暂停中：正在看视频"
        case .fullscreen: base = "暂停中：全屏中"
        }
        return L(base)
    }
}

/// Which app is using a microphone. Public CoreAudio process objects (macOS 14+), query only,
/// no microphone permission. Helper processes (e.g. Chrome Helper) map to their parent app.
enum MicUserMonitor {
    /// Pids currently recording from an input device; nil when the API is unavailable (< macOS 14).
    static func inputPids() -> [pid_t]? {
        guard #available(macOS 14.0, *) else { return nil }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        var out: [pid_t] = []
        for id in ids {
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0; var s = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &running) == noErr, running != 0 else { continue }
            a.mSelector = kAudioProcessPropertyPID
            var pid: pid_t = 0; s = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &pid) == noErr else { continue }
            out.append(pid)
        }
        return out
    }

    /// Input methods (e.g. WeChat IME voice typing) are typing, not a meeting. Identified by type,
    /// not a list: installed input sources from Text Input Sources (public HIToolbox), plus any
    /// bundle living in an "Input Methods" folder.
    static func isInputMethod(_ pid: pid_t) -> Bool {
        guard let path = ProcessLineage.path(of: pid) else { return false }
        if path.contains("/Input Methods/") { return true }
        let outer = ProcessLineage.outerAppBundle(path) ?? path
        guard let id = Bundle(path: outer)?.bundleIdentifier else { return false }
        return inputMethodBundleIDs().contains(id)
    }

    /// Text Input Sources must be read on the main thread: macOS 27.2 asserts the main queue inside
    /// TISCreateInputSourceList and kills the process. Read there, at start and whenever the enabled
    /// input sources change; the detector queue only reads this copy.
    private final class IMCache: @unchecked Sendable { let lock = NSLock(); var ids: Set<String> = [] }
    private static let imCache = IMCache()

    static func inputMethodBundleIDs() -> Set<String> {
        imCache.lock.lock(); defer { imCache.lock.unlock() }
        return imCache.ids
    }

    static func watchInputMethods() {
        DispatchQueue.main.async {
            reloadInputMethods()
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                object: nil, queue: .main) { _ in reloadInputMethods() }
        }
    }

    private static func reloadInputMethods() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else { return }
        var out = Set<String>()
        for src in list {
            guard let raw = TISGetInputSourceProperty(src, kTISPropertyBundleID) else { continue }
            out.insert(Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String)
        }
        imCache.lock.lock(); imCache.ids = out; imCache.lock.unlock()
    }

    /// Is anything other than an input method recording? nil = can't tell (fall back to device state).
    static func nonInputMethodInUse() -> Bool? {
        guard let pids = inputPids() else { return nil }
        return pids.contains { !isInputMethod($0) }
    }

    static func appsUsingInput() -> [NSRunningApplication] {
        guard let pids = inputPids() else { return [] }
        let apps = NSWorkspace.shared.runningApplications
        var out: [NSRunningApplication] = []
        for pid in pids where !isInputMethod(pid) {
            if let app = owningApp(pid, apps: apps), !out.contains(app) { out.append(app) }
        }
        return out
    }

    /// The regular app a pid belongs to (itself, an ancestor, or the outer .app bundle).
    static func owningApp(_ pid: pid_t, apps: [NSRunningApplication]) -> NSRunningApplication? {
        for p in ProcessLineage.lineage(of: pid) {
            if let a = apps.first(where: { $0.processIdentifier == p && $0.activationPolicy == .regular }) { return a }
        }
        if let path = ProcessLineage.path(of: pid), let outer = ProcessLineage.outerAppBundle(path) {
            return apps.first { $0.bundleURL?.path == outer }
        }
        return nil
    }

    /// Best app to name for a meeting: a known meeting app, then a browser, then anything.
    static func meetingApp() -> NSRunningApplication? {
        let users = appsUsingInput()
        return users.first { ScreenShareMonitor.meetingBundleIDs.contains($0.bundleIdentifier ?? "") }
            ?? users.first { BrowserVideoMonitor.browserBundleIDs.contains($0.bundleIdentifier ?? "") }
            ?? users.first
    }
}
