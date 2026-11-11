import AppKit
import Combine
import CoreGraphics
import PausaCore

/// Glue: detector + input idle + monotonic clock -> Scheduler -> overlay & menu bar.
/// Owns no policy of its own; every timing decision lives in PausaCore.Scheduler.
@MainActor
final class AppController {
    private(set) var scheduler: PausaCore.Scheduler
    let detector: PauseDetector
    let overlay = BreakOverlayController()
    let preBreak = PreBreakController()
    /// 提示音: sounds loaded once, at launch.
    let chime = BreakChime()
    let settings: Settings
    let log: BreakLog
    let clock: PausaClock

    private let injectedDefaults: UserDefaults?
    private let inputIdleProvider: () -> Double
    private let showUI: Bool

    private var store: UserDefaults { injectedDefaults ?? PausaDefaults.store }
    private var isIsolated: Bool { injectedDefaults != nil || Settings.dryRun }

    private var pauseCap = PauseCap()
    private var rawReasons: Set<PauseReason> = []
    private(set) var reasons: [PausaCore.PauseReason: String] = [:]   // reason -> full 「已暂停：…」 line
    /// 暂停提醒 (spec-hardline: no expiry): when it was pressed, nil when not paused. Kept in UserDefaults
    /// ("manualPaused" + "manualPausedSince", wall clock) so a quit or restart doesn't drop it.
    private(set) var manualPausedSince: Date?
    var manualPaused: Bool { manualPausedSince != nil }
    private var awaySince: Double?
    private var timer: Timer?
    private var bag: Set<AnyCancellable> = []
    private var hoursGate = HoursGate()
    private var boundaryTimer: Timer?
    /// Wall-clock calendar that follows time-zone / locale changes.
    private var cal: Calendar { Calendar.autoupdatingCurrent }
    var onChange: (() -> Void)?
    /// A break just ended (completed, skipped, snoozed): lets the updater run a held install.
    var onBreakEnded: (() -> Void)?
    private var lastSave: Double = 0

    init(settings: Settings = .shared,
         detector: PauseDetector? = nil,
         log: BreakLog = .shared,
         clock: PausaClock = .system,
         defaults: UserDefaults? = nil,
         inputIdle: (() -> Double)? = nil,
         showUI: Bool = true) {
        self.settings = settings
        self.detector = detector ?? PauseDetector(defaults: defaults, clock: clock)
        self.log = log
        self.clock = clock
        self.injectedDefaults = defaults
        self.inputIdleProvider = inputIdle ?? Self.inputIdle
        self.showUI = showUI
        scheduler = PausaCore.Scheduler(config: settings.config)

        restoreState()
        let ud = defaults ?? PausaDefaults.store
        if ud.bool(forKey: DefaultsKey.manualPaused) {
            let t = ud.double(forKey: DefaultsKey.manualPausedSince)
            manualPausedSince = t > 0 ? Date(timeIntervalSince1970: t) : clock.wallNow()
        }

        self.detector.$reasons.sink { [weak self] r in
            guard let self else { return }
            self.rawReasons = r
            self.updateReasons(r)
        }.store(in: &bag)

        // @Published fires before the value changes (`willSet`), so re-evaluate on the next run-loop turn
        // (or immediately when tests pump or read after `didSet`).
        settings.$pauseForMeetings.dropFirst().sink { [weak self] newValue in
            guard let self else { return }
            self.updateReasons(self.rawReasons, pauseForMeetings: newValue)
            self.detector.refreshNow()
            DispatchQueue.main.async { [weak self] in self?.tick() }
        }.store(in: &bag)

        for pub in [
            settings.$pauseWhileTyping.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$pauseForBrowserVideo.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$pauseForScreenSharing.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$pauseForCustomApps.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$customPauseApps.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$pauseForFocusMode.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$focusModeScope.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ] {
            pub.sink { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.detector.refreshNow()
                    self?.tick()
                }
            }.store(in: &bag)
        }

        settings.$showPreBreakPanel.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.refreshPreBreak() } }.store(in: &bag)
        settings.$showPreBreakPill.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.refreshPreBreak() } }.store(in: &bag)
        self.detector.onAway = { [weak self] e in self?.handleAway(e) }
        preBreak.onStartNow = { [weak self] in
            guard let self, let k = self.scheduler.preBreak?.kind else { return }
            self.breakNow(k)
        }
        preBreak.onPostpone = { [weak self] in
            guard let self else { return }
            self.postpone(by: self.scheduler.config.snoozeLength)
        }
        preBreak.onSkip = { [weak self] in
            guard let self else { return }
            self.apply(self.scheduler.skipUpcoming(now: self.clock.continuousNow()))
        }
        preBreak.onUrgent = { [weak self] in self?.urgentPause() }
        settings.onChange = { [weak self] c in self?.scheduler.config = c; self?.onChange?() }
        settings.onScheduleChange = { [weak self] in self?.scheduleChanged() }

        // Wall clock moved under us: re-evaluate 时段 and re-arm the boundary timer.
        let nc = NotificationCenter.default
        for n in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleChanged() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleChanged() }
        }
    }

    // MARK: Pausa 时段

    var outsideHours: Bool { !isActive(settings.schedule, at: clock.wallNow(), cal: cal) }

    /// Next window start, for the menu ("下次开始 9:00"). nil when the schedule is off.
    var nextWindowStart: Date? { outsideHours ? nextStart(settings.schedule, after: clock.wallNow(), cal: cal) : nil }

    private func scheduleChanged() {
        armBoundaryTimer()
        tick()
    }

    /// One-shot timer at the next window edge so the switch is exact even if ticks are coalesced.
    private func armBoundaryTimer() {
        boundaryTimer?.invalidate(); boundaryTimer = nil
        guard let at = nextChange(settings.schedule, after: clock.wallNow(), cal: cal) else { return }
        let t = Timer(fire: at.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleChanged() }
        }
        RunLoop.main.add(t, forMode: .common)
        boundaryTimer = t
    }

    func start() {
        wasTimerStarted = true
        detector.start()
        startTickTimer()
        armBoundaryTimer()
        tick()
    }

    func stop() {
        wasTimerStarted = false
        timer?.invalidate(); timer = nil
        boundaryTimer?.invalidate(); boundaryTimer = nil
        detector.stop()
    }

    private func startTickTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Monotonic seconds that keep counting while the Mac sleeps.
    static func now() -> Double { PausaClock.system.continuousNow() }

    static func inputIdle() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: persistence (time since last long break, shared defer budget, hard line)

    /// Wall clock for the quit-to-launch gap (monotonic time restarts with the process).
    private func wallClock() -> Double { clock.wallNow().timeIntervalSince1970 }

    private func restoreState() {
        guard let data = store.data(forKey: DefaultsKey.schedulerState),
              let saved = try? JSONDecoder().decode(PausaCore.Scheduler.Saved.self, from: data) else { return }
        scheduler.restore(saved, wallClock: wallClock(), now: clock.continuousNow())
    }

    /// Called every minute from tick(), on quit, and right before an update relaunch.
    func saveState() {
        guard let data = try? JSONEncoder().encode(scheduler.saved(wallClock: wallClock())) else { return }
        store.set(data, forKey: DefaultsKey.schedulerState)
        lastSave = clock.continuousNow()
    }

    /// True while a break is on screen: update installs wait until it ends.
    var isOnBreak: Bool { if case .onBreak = scheduler.phase { return true }; return false }

    // MARK: driving the scheduler

    func tick() {
        let now = clock.continuousNow()
        if now - lastSave >= 60 { saveState() }
        if manualPaused {   // until 恢复提醒; a lock resets the clock (away) but doesn't end the pause
            let idle = inputIdleProvider()
            scheduler.manualPauseTick(now: now)
            if showUI { preBreak.update(nil, removal: .animated) }
            trackWork(now: now, idle: idle, inHours: awaySince == nil && !outsideHours, holding: false)   // 暂停提醒 is still work; a lock is not
            onChange?()   // refresh every tick; the 「提醒已暂停 N 分钟」 text itself only changes each whole minute
            return
        }
        if awaySince != nil { return }

        let active = !outsideHours
        if hoursGate.update(active) { scheduler.startFresh(now: now) }   // a window just opened
        var rs = pauseCap.filter(Set(reasons.keys), now: now)   // 2 h cap (video/fullscreen drop)
        if !active { rs.insert(.outsideHours) }

        let idle = inputIdleProvider()
        // No input is not rest, and not getting up either: only a locked screen counts (away).
        apply(scheduler.tick(now: now, reasons: rs, deferrals: detector.allDeferrals, inputIdle: idle))
        trackWork(now: now, idle: idle, inHours: active, holding: !rs.isDisjoint(with: Self.holds))
        onChange?()
    }

    // MARK: work time (stats)

    private var work = WorkClock()
    /// The stats page refreshes at once when a break ends or data is cleared.
    var onStatsChanged: (() -> Void)?
    private var lastWorkCheckpoint: Double = 0
    private static let workCheckpointEvery: Double = 300

    private static let holds: Set<PausaCore.PauseReason> = [.meeting, .micInUse, .screenSharing, .video, .fullscreen]

    /// After the scheduler has moved, so a break that just started ends the span at its start.
    /// Hours come from `isActive` directly, not from the phase: a meeting outside hours shows as .paused(.meeting).
    private func trackWork(now: Double, idle: Double, inHours: Bool, holding: Bool) {
        var counting = inHours
        if case .onBreak = scheduler.phase { counting = false }
        if let s = work.update(now: now, counting: counting, holding: holding, inputIdle: idle, idleLimit: scheduler.config.longLength) {
            log.append(span(s))
        } else if let open = work.openedAt, now - lastWorkCheckpoint >= Self.workCheckpointEvery {
            log.checkpoint(span((open, now)))
            lastWorkCheckpoint = now
        }
    }

    /// 清除数据…: everything goes, and the span running now starts over from this moment.
    func clearStats() {
        log.clear()
        if work.openedAt != nil { _ = work.close(at: clock.continuousNow()) }
        lastWorkCheckpoint = 0
        onStatsChanged?()
    }

    /// The span running now, up to this moment (not in the log until it closes). For today's numbers.
    var openWorkSpan: WorkSpan? { work.openedAt.map { span(($0, clock.continuousNow())) } }

    /// Lock, quit.
    func endWork() { endWork(at: clock.continuousNow()) }

    private func endWork(at now: Double) {
        if let s = work.close(at: now) { log.append(span(s)) }
    }

    /// Monotonic seconds to dates, through the current offset between the two clocks.
    private func span(_ s: (start: Double, end: Double)) -> WorkSpan {
        let now = clock.continuousNow(), wall = clock.wallNow()
        return WorkSpan(start: wall.addingTimeInterval(s.start - now), end: wall.addingTimeInterval(s.end - now))
    }

    /// `chime: false` when coming back from a lock: a break that ran out meanwhile ends quietly.
    private func apply(_ cmds: [PausaCore.Command], chime chimes: Bool = true) {
        for c in cmds {
            defer { if chimes && showUI { chime.play(for: c, sound: settings.breakSound, reasons: chimeReasons) } }   // after the overlay is up
            switch c {
            case .showWarning:
                break   // 面板由 `scheduler.preBreak` 驱动 (refreshPreBreak below); the menu bar icon reflects .warning on the next refresh
            case .recorded(let kind, let planned, let result):
                log.append(BreakRecord(start: breakStart ?? clock.wallNow(), kind: kind, planned: planned, result: result))
                breakStart = nil
                onStatsChanged?()
            case .startBreak(.short, let len):
                breakStart = clock.wallNow()
                guard showUI else { break }
                overlay.showShort(duration: len,
                                  onSkip: { [weak self] in self?.finish(.skipped) },
                                  onFinish: { [weak self] in self?.finish(.completed) })
            case .startBreak(.long, let len):
                breakStart = clock.wallNow()
                guard showUI else { break }
                overlay.showLong(duration: len,
                                 onSnooze: { [weak self] m in self?.snooze(minutes: m) },
                                 onSkip: { [weak self] in self?.finish(.skipped) },
                                 onFinish: { [weak self] in self?.finish(.completed) },
                                 show15: scheduler.postponeBudget(.long) >= Self.postponeLong,
                                 can15: scheduler.deferralLeft >= Self.postponeLong,
                                 mustNotDefer: scheduler.longMustNotDefer,
                                 onUrgent: { [weak self] in self?.urgentPause() })
            case .resumeBreak(.short, let left):
                guard showUI else { break }
                overlay.showShort(duration: left,
                                  onSkip: { [weak self] in self?.finish(.skipped) },
                                  onFinish: { [weak self] in self?.finish(.completed) })
            case .resumeBreak(.long, let left):
                guard showUI else { break }
                overlay.showLong(duration: left,
                                 onSnooze: { [weak self] m in self?.snooze(minutes: m) },
                                 onSkip: { [weak self] in self?.finish(.skipped) },
                                 onFinish: { [weak self] in self?.finish(.completed) },
                                 show15: scheduler.postponeBudget(.long) >= Self.postponeLong,
                                 can15: scheduler.deferralLeft >= Self.postponeLong,
                                 mustNotDefer: scheduler.longMustNotDefer,
                                 onUrgent: { [weak self] in self?.urgentPause() })
            case .endBreak:
                if showUI { overlay.dismiss() }
                onBreakEnded?()
            }
        }
        refreshPreBreak(immediate: cmds.contains { if case .startBreak = $0 { return true }; if case .resumeBreak = $0 { return true }; return false })
        onChange?()
    }

    /// Hand the scheduler's current pre-break state to the panel. A break that just started removes it at once;
    /// anything else retracts it. Manual pause and away show nothing (spec 7.4).
    private func refreshPreBreak(immediate: Bool = false) {
        guard showUI else { return }
        let hidden = manualPaused || awaySince != nil
        let shown = hidden ? nil : scheduler.preBreak?.masked(panel: settings.showPreBreakPanel, pointer: settings.showPreBreakPill)
        preBreak.update(shown, removal: immediate ? .immediate : .animated)
    }

    /// Wall-clock start of the break on screen, for its stats row (the scheduler runs on a monotonic clock).
    private var breakStart: Date?

    private func finish(_ o: BreakOutcome) { apply(scheduler.finish(o, now: clock.continuousNow())) }

    /// Break screen 「休息延后 N 分钟」: a snooze brings the break back in snoozeLength (5 min);
    /// 15 adds the rest from the shared postpone allowance.
    private func snooze(minutes: Int) {
        finish(.snoozed)
        let extra = Double(minutes) * 60 - scheduler.config.snoozeLength
        if extra > 0, scheduler.canPostpone(by: extra) { postpone(by: extra) }
    }

    /// Pretend the detector reported these reasons (used by `--capture-menu --meeting` and unit tests).
    func simulateReasons(_ r: Set<PauseReason>) {
        rawReasons = r
        updateReasons(r)
        tick()
    }

    private func updateReasons(_ r: Set<PauseReason>, pauseForMeetings: Bool? = nil) {
        let meetingsEnabled = pauseForMeetings ?? settings.pauseForMeetings
        var m: [PausaCore.PauseReason: String] = [:]
        for x in r {
            if x.core == .meeting || x.core == .micInUse, !meetingsEnabled { continue }   // 自动暂停 → 开会时 off
            switch x {
            case .meeting, .micInUse, .fullscreen: m[x.core] = x.pausedText
            default: if m[x.core] == nil { m[x.core] = x.pausedText }   // Linus: video / share / recording
            }
        }
        reasons = m
        onChange?()
    }

    func handleAway(_ e: PauseDetector.AwayEvent) {
        let now = clock.continuousNow()
        switch e {
        case .start:
            endWork(at: now)
            awaySince = now
            if timer != nil, !manualPaused {
                timer?.invalidate(); timer = nil
            }
            if showUI {
                overlay.dismiss(animated: false)
                preBreak.update(nil, removal: .immediate)
            }
        case .end:
            let secs = awaySince.map { now - $0 } ?? 0
            awaySince = nil
            apply(scheduler.away(.locked, seconds: secs, now: now), chime: false)
            if timer == nil, wasTimerStarted { startTickTimer() }
            tick()
        }
        onChange?()
    }

    private var wasTimerStarted = false

    // MARK: menu actions

    func breakNow(_ kind: BreakKind) { apply(scheduler.breakNow(kind, now: clock.continuousNow())) }

    /// Popover +5分 / +15分: push the next break back within the shared budget (greyed out otherwise).
    func postpone(by seconds: Double) { scheduler.postpone(by: seconds); refreshPreBreak(); onChange?() }

    /// Settings "预览": 5 s of the long-break scene. Never touches the scheduler. Chimes like a real
    /// long break: start now, end when the 5 s run out. The end sound lives only in onFinish, which only
    /// the overlay's countdown calls; skip, snooze and dismiss stop the countdown and clear onFinish first.
    func previewLong() {
        if case .onBreak = scheduler.phase { return }
        guard showUI else { return }
        overlay.showLong(duration: 5, onSnooze: { _ in }, onSkip: {},
                         onFinish: { [weak self] in
                             guard let self else { return }
                             self.chime.play(for: .recorded(.long, planned: 5, .completed), sound: self.settings.breakSound, reasons: self.chimeReasons)
                         })
        chime.play(for: .startBreak(.long, length: 5), sound: settings.breakSound, reasons: chimeReasons)
    }

    /// What the detector sees right now, unfiltered by the 自动暂停 switches: a call is a call.
    var chimeReasons: Set<PausaCore.PauseReason> { Set(rawReasons.map(\.core)) }

    /// Menu 暂停提醒: no record of its own. A break on screen ends as skipped (one row); past the hard
    /// line skip is refused, so it takes the urgent exit instead (also one skipped row).
    func pause() {
        let wasOnBreak = isOnBreak
        setManualPause(clock.wallNow())
        if wasOnBreak {
            var cmds = scheduler.finish(.skipped, now: clock.continuousNow())
            if cmds.isEmpty { cmds = scheduler.urgentPause(now: clock.continuousNow()) }
            apply(cmds)
        }
        if showUI {
            overlay.dismiss()
            preBreak.update(nil, removal: .animated)
        }
        onChange?()
    }

    /// 「紧急暂停提醒」 (long-break screen / pre-break panel, only at the hard line): end that long
    /// break as exactly one skip, then pause reminders as the menu does.
    func urgentPause() {
        setManualPause(clock.wallNow())
        apply(scheduler.urgentPause(now: clock.continuousNow()))
        if showUI {
            overlay.dismiss()
            preBreak.update(nil, removal: .immediate)
        }
        onChange?()
    }

    func resume() {
        setManualPause(nil)
        // The pause counted toward the hard line; past it, the long break starts now.
        apply(scheduler.manualPauseEnded(now: clock.continuousNow()))
        onChange?()
    }

    private func setManualPause(_ since: Date?) {
        manualPausedSince = since
        let d = store
        d.set(since != nil, forKey: DefaultsKey.manualPaused)
        if let since { d.set(since.timeIntervalSince1970, forKey: DefaultsKey.manualPausedSince) }
        else { d.removeObject(forKey: DefaultsKey.manualPausedSince) }
    }

    // MARK: what the menu shows

    /// v2 status (§6.2) for AutoPauseStatus: hold reasons first, then the active deferral.
    var autoPauseStatus: AutoPauseStatus? {
        if case .paused(let top) = scheduler.phase {
            for r in rawReasons where r.core == top {
                switch r {
                case .browserVideo(let a): return .browserVideo(app: a)
                case .screenSharing(let a): return .screenSharing(app: a)
                case .recording(let a): return .screenRecording(app: a)
                default: break
                }
            }
            return nil
        }
        switch scheduler.deferring {
        case .typing?: return .typing(secondsLeft: scheduler.deferralLeft(for: .typing, cap: Deferral.typing.cap))
        case .microphone?: return .typing(secondsLeft: scheduler.deferralLeft(for: .microphone, cap: Deferral.microphone.cap))   // dictation reads as typing
        case .focusApp?:
            let m = Int((scheduler.deferralLeft(for: .focusApp, cap: Deferral.focusApp().cap) / 60).rounded(.up))
            return .customApp(app: detector.customAppName ?? "", minutesLeft: m)
        case .focusMode?: return .focus(name: nil, scope: settings.focusModeScope)
        case nil: return nil
        }
    }

    var statusLine: String {
        if let since = manualPausedSince {   // 「提醒已暂停 2 小时 10 分钟」, whole minutes; under a minute just 「提醒已暂停」
            let minutes = (max(0, clock.wallNow().timeIntervalSince(since)) / 60).rounded(.down)
            return minutes < 1 ? L("status.paused") : L("status.pausedFor", StatsText.duration(minutes * 60))
        }
        if awaySince != nil { return L("status.away") }
        if case .paused(.outsideHours) = scheduler.phase {
            guard let next = nextWindowStart else { return L("status.outsideHours") }
            return L("status.nextStart", Self.whenText(next, cal: cal))
        }
        var reasonText: String?
        if case .paused(let top) = scheduler.phase { reasonText = reasons[top] }
        if let t = StatusPick.line(source: currentPauseSource?.statusText,
                                   autoStatus: autoPauseStatus?.title, reason: reasonText) { return t }
        if case .onBreak(let k, _) = scheduler.phase { return k == .long ? L("status.onLongBreak") : L("status.onShortBreak") }
        let n = scheduler.next
        return L(n.kind == .long ? "status.longIn" : "status.shortIn", Self.clock(n.remaining))
    }

    /// Source holding the current pause (Mitchell: icon from `bundleID`). nil = not auto-paused.
    var currentPauseSource: PauseSource? {
        if case .paused(let top) = scheduler.phase { return pauseSource(for: top) }
        return nil
    }
    private func pauseSource(for r: PausaCore.PauseReason) -> PauseSource? {
        if let s = detector.sources[r] { return s }
        switch r {   // reason without detector data (e.g. debug simulate): text only
        case .meeting, .micInUse: return PauseSource(kind: .meeting)
        default: return nil
        }
    }

    var isPaused: Bool {
        if manualPaused || awaySince != nil { return true }
        if case .paused = scheduler.phase { return true }
        return false
    }

    /// "9:00" today, "明天 9:00" tomorrow, else "周一 9:00" (app language).
    static func whenText(_ d: Date, cal: Calendar) -> String {
        let f = DateFormatter(); f.locale = AppLanguage.current.locale
        f.setLocalizedDateFormatFromTemplate("Hmm")
        let time = f.string(from: d)
        if cal.isDateInToday(d) { return time }
        if cal.isDateInTomorrow(d) { return L("status.tomorrow", time) }
        f.setLocalizedDateFormatFromTemplate("EEE Hmm")
        return f.string(from: d)
    }

    /// The menu's +5 / +15 minute postpone steps.
    nonisolated static let postponeShort: Double = 5 * 60, postponeLong: Double = 15 * 60

    static func clock(_ s: Double) -> String {
        let s = max(0, Int(s.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : colonPair(s)
    }

    /// "m:ss" for seconds, or "h:mm" for minutes: n / 60 and n % 60 joined with a colon.
    nonisolated static func colonPair(_ n: Int) -> String { String(format: "%d:%02d", n / 60, n % 60) }
}
