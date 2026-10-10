import AppKit
import Combine

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

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let micOrCam = AudioInputMonitor.anyPhysicalInputRunning() || CameraMonitor.anyRunning()
        if micOrCam { lastMeetingSignal = now }
        let inMeeting = lastMeetingSignal.map { now - $0 < meetingGrace } ?? false

        var next: Set<PauseReason> = []
        if inMeeting { next.insert(.meeting) }
        if let fs = FullscreenMonitor.check() { next.insert(.fullscreen(appName: fs.appName)) }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.reasons != next else { return }
            self.reasons = next
        }
    }

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
