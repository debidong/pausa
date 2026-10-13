import AppKit
import Combine
import PausaCore

typealias PausaCoreReason = PausaCore.PauseReason

/// Auto-pause signals for the state machine.
///
/// - `reasons`: current pause reasons (published on the main thread).
/// - `onAway`: called on main with `.start(kind)` when the user leaves
///   (screen locked, display asleep, system sleep) and `.end(kind)` when they
///   are back. Only the first start / last end is reported, so nested
///   lock+sleep yields exactly one start and one end.
///
/// Polls every 1 s on a utility queue; each tick is a handful of CoreAudio /
/// CMIO property reads plus one CGWindowList call. Nothing needs a TCC prompt.
public final class PauseDetector: ObservableObject {
    public enum AwayKind: String { case screenLocked, displayAsleep, systemAsleep }
    public enum AwayEvent { case start(AwayKind), end(AwayKind) }

    @Published public private(set) var reasons: Set<PauseReason> = []
    /// Soft deferrals (§0 R1) for the scheduler; it owns all timing and the shared budget.
    @Published public private(set) var deferrals: [Deferral] = []
    /// True while locked / asleep. Mirrors onAway.
    @Published public private(set) var isAway = false

    public var onAway: ((AwayEvent) -> Void)?

    /// Keep `.meeting` this long after mic/camera stop (PRD: 2 minutes).
    public var meetingGrace: TimeInterval = 120
    public var pollInterval: TimeInterval = 1

    private let queue = DispatchQueue(label: "pausa.detector", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastMeetingSignal: TimeInterval?   // monotonic (systemUptime)
    private var awayKinds: Set<AwayKind> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    public init() {}
    deinit { stop() }

    public func start() {
        guard timer == nil else { return }
        observeAway()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel(); timer = nil
        for (c, o) in observers { c.removeObserver(o) }
        observers.removeAll()
    }

    // MARK: polling

    // Settings keys owned by Mitchell's Settings.swift; read directly so Detection does not
    // depend on the settings UI layer.
    private func flag(_ key: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? def : UserDefaults.standard.bool(forKey: key)
    }

    private var lastVideo: (name: String, at: TimeInterval)?
    private var lastShare: (reason: PauseReason, at: TimeInterval)?

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let micOrCam = AudioInputMonitor.anyPhysicalInputRunning() || CameraMonitor.anyRunning()
        if micOrCam { lastMeetingSignal = now }
        let inMeeting = lastMeetingSignal.map { now - $0 < meetingGrace } ?? false

        var next: Set<PauseReason> = []
        if inMeeting { next.insert(.meeting) }
        if let fs = FullscreenMonitor.check() { next.insert(.fullscreen(appName: fs.appName)) }

        // §1 browser video, 2-min grace after the assertion drops (R5, reuses meetingGrace).
        if flag("pauseForBrowserVideo", default: true) {
            if let b = BrowserVideoMonitor.check() { lastVideo = (b, now) }
            if let v = lastVideo, now - v.at < meetingGrace { next.insert(.browserVideo(appName: v.name)) }
        } else { lastVideo = nil }

        // §2 screen sharing / recording, same grace.
        if flag("pauseForScreenSharing", default: true) {
            switch ScreenShareMonitor.check(inMeeting: micOrCam || inMeeting) {
            case .sharing(let a)?: lastShare = (.screenSharing(appName: a), now)
            case .recording(let a)?: lastShare = (.recording(appName: a), now)
            case nil: break
            }
            if let s = lastShare, now - s.at < meetingGrace { next.insert(s.reason) }
        } else { lastShare = nil }

        // §4 typing / dragging: report only kind + cap; the scheduler decides when it matters.
        var defs: [Deferral] = []
        if flag("pauseWhileTyping", default: true), InputActivityMonitor.isBusy() { defs.append(.typing) }
        // §3 custom apps (15 min cap, shared budget).
        let custom = CustomPauseAppMonitor.check()
        if custom != nil { defs.append(.focusApp()) }
        // §5 macOS Focus (filter itself is on hold; we only read the state it writes).
        if flag("pauseForFocusMode", default: true), UserDefaults.standard.bool(forKey: "focusFilterActive") {
            defs.append(.focusMode(shortOnly: UserDefaults.standard.string(forKey: "focusModeScope") != "all"))
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.customAppName = custom
            if self.deferrals != defs { self.deferrals = defs }
            if self.reasons != next { self.reasons = next }
        }
    }

    /// Adds a soft deferral from another source (focus apps / Focus filter, Mitchell's side).
    /// Kept here so all sources flow through the same list. Call on main.
    public var extraDeferrals: [Deferral] = []
    /// Name of the custom pause app currently matching (for 「已推迟：Xcode 在前台」).
    public private(set) var customAppName: String?
    public var allDeferrals: [Deferral] { deferrals + extraDeferrals }

    // MARK: lock / sleep

    private func observeAway() {
        let ws = NSWorkspace.shared.notificationCenter
        let dn = DistributedNotificationCenter.default()
        func add(_ c: NotificationCenter, _ name: Notification.Name, _ kind: AwayKind, _ begins: Bool) {
            let o = c.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.setAway(kind, begins)
            }
            observers.append((c, o))
        }
        add(ws, NSWorkspace.willSleepNotification, .systemAsleep, true)
        add(ws, NSWorkspace.didWakeNotification, .systemAsleep, false)
        add(ws, NSWorkspace.screensDidSleepNotification, .displayAsleep, true)
        add(ws, NSWorkspace.screensDidWakeNotification, .displayAsleep, false)
        add(dn, Notification.Name("com.apple.screenIsLocked"), .screenLocked, true)
        add(dn, Notification.Name("com.apple.screenIsUnlocked"), .screenLocked, false)
    }

    private func setAway(_ kind: AwayKind, _ begins: Bool) {
        let wasAway = !awayKinds.isEmpty
        if begins { awayKinds.insert(kind) } else { awayKinds.remove(kind) }
        let nowAway = !awayKinds.isEmpty
        guard wasAway != nowAway else { return }
        isAway = nowAway
        onAway?(nowAway ? .start(kind) : .end(kind))
    }
}
