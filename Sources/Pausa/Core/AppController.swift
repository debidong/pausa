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
    let overlay: BreakOverlayController
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
    /// 暂停提醒 (auto-expires at end of day or next PausaSchedule window): projected directly from `scheduler.manualPause`.
    var manualPausedSince: Date? {
        if case .paused(let sinceWall, _) = scheduler.manualPause {
            return Date(timeIntervalSince1970: sinceWall)
        }
        return nil
    }
    var manualPaused: Bool { scheduler.isManuallyPaused }
    private var timer: Timer?
    private var bag: Set<AnyCancellable> = []
    private var hoursGate = HoursGate()
    private var boundaryTimer: Timer?
    /// Wall-clock calendar that follows time-zone / locale changes.
    private var cal: Calendar { Calendar.autoupdatingCurrent }
    var onChange: (() -> Void)?
    /// Fired whenever a break or full-screen preview clears, letting `Updater` run any held install.
    var onOverlayCleared: (() -> Void)?
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
        self.overlay = BreakOverlayController(rendersWindows: showUI)
        self.log = log
        self.clock = clock
        self.injectedDefaults = defaults
        self.inputIdleProvider = inputIdle ?? Self.inputIdle
        self.showUI = showUI
        scheduler = PausaCore.Scheduler(config: settings.config)

        restoreState()

        self.overlay.onPresentationEnded = { [weak self] in
            guard let self else { return }
            self.refreshPreBreak()
            self.onChange?()
            if !self.blocksRelaunch { self.onOverlayCleared?() }
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
        let now = clock.continuousNow()
        let wall = wallClock()
        if let data = store.data(forKey: DefaultsKey.schedulerState),
           let saved = try? JSONDecoder().decode(PausaCore.Scheduler.Saved.self, from: data) {
            scheduler.restore(saved, wallClock: wall, now: now)
        }
        // Forward migration from pre-0.6.3 split manualPaused keys into Scheduler.Saved.
        if store.object(forKey: DefaultsKey.manualPaused) != nil {
            if store.bool(forKey: DefaultsKey.manualPaused), !scheduler.isManuallyPaused {
                let t = store.double(forKey: DefaultsKey.manualPausedSince)
                let sinceWall = t > 0 ? t : wall
                _ = scheduler.pauseManually(wallNow: sinceWall, now: now)
            }
            store.removeObject(forKey: DefaultsKey.manualPaused)
            store.removeObject(forKey: DefaultsKey.manualPausedSince)
            saveState()
        }
    }

    /// Called every minute from tick(), on manual-pause toggles, on quit, and right before an update relaunch.
    func saveState() {
        guard let data = try? JSONEncoder().encode(scheduler.saved(wallClock: wallClock())) else { return }
        store.set(data, forKey: DefaultsKey.schedulerState)
        lastSave = clock.continuousNow()
    }

    /// True while a scheduled break is active in the scheduler.
    var isOnBreak: Bool { if case .onBreak = scheduler.phase { return true }; return false }

    /// True while any break or full-screen preview is up: blocks Sparkle relaunches.
    var blocksRelaunch: Bool { isOnBreak || overlay.presentation.isPresenting }

    /// Raw physical engagement (call, video, fullscreen, screen share) independent of user auto-pause toggles.
    var isScreenEngaged: Bool {
        if let override = detector.screenEngagedOverride { return override }
        return detector.isScreenEngaged || !rawReasons.isEmpty
    }

    // MARK: driving the scheduler

    func tick() {
        let now = clock.continuousNow()
        if now - lastSave >= 60 { saveState() }
        if scheduler.isLockedAway { return }

        let active = !outsideHours
        let idle = inputIdleProvider()
        let engaged = isScreenEngaged
        let wall = wallClock()

        // Entering an active PausaSchedule window starts fresh and clears any lingering manual pause.
        if hoursGate.update(active) {
            if scheduler.isManuallyPaused { _ = scheduler.resumeManually(now: now) }
            scheduler.startFresh(now: now)
            saveState()
        }

        if scheduler.isManuallyPaused {   // until 恢复提醒 or auto-expiry; away freezes the clock without ending the pause
            let cmds = scheduler.tick(now: now, reasons: active ? [] : [.outsideHours], deferrals: [],
                                      inputIdle: idle, screenEngaged: engaged, wallNow: wall)
            if !cmds.isEmpty || !scheduler.isManuallyPaused {
                saveState()
                if !cmds.isEmpty { apply(cmds) }
            }
            if scheduler.isManuallyPaused {
                refreshPreBreak()
                trackWork(now: now, idle: idle, inHours: active, pauseHolding: false, presenceHolding: engaged, unboundedHold: false)
                onChange?()   // refresh every tick; 「提醒已暂停 N 分钟」 updates each whole minute
                return
            }
        }

        var rs = pauseCap.filter(Set(reasons.keys), now: now)   // 2 h cap (video/fullscreen drop)
        if !active { rs.insert(.outsideHours) }

        apply(scheduler.tick(now: now, reasons: rs, deferrals: detector.allDeferrals,
                             inputIdle: idle, screenEngaged: engaged, wallNow: wall))
        let pauseHolding = !rs.isDisjoint(with: Self.holds)
        let presenceHolding = engaged || pauseHolding
        let unboundedHold = !rs.isDisjoint(with: Self.unboundedHolds)
        trackWork(now: now, idle: idle, inHours: active,
                  pauseHolding: pauseHolding, presenceHolding: presenceHolding, unboundedHold: unboundedHold)
        onChange?()
    }

    // MARK: work time (stats)

    private var work = WorkClock()
    private var openSpanIsHold = false
    /// The stats page refreshes at once when a break ends or data is cleared.
    var onStatsChanged: (() -> Void)?
    private var lastWorkCheckpoint: Double = 0
    private static let workCheckpointEvery: Double = 300
    /// Injectable frontmost regular-app reader (public NSWorkspace API, zero TCC permissions).
    var frontmostAppProvider: () -> (bundleID: String, name: String)? = AppController.systemFrontmostApp
    private var lastAppSampleAt: Double?
    private var lastActiveApp: (bundleID: String, name: String)?
    private var breakTriggerApp: (bundleID: String, name: String)?
    private var recentAppSlices: [(at: Double, day: Date, bundleID: String, seconds: Double)] = []

    nonisolated static func systemFrontmostApp() -> (bundleID: String, name: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              let id = app.bundleIdentifier, !id.isEmpty else { return nil }
        if id == Bundle.main.bundleIdentifier { return nil }
        return (id, app.localizedName ?? id)
    }

    private static let holds: Set<PausaCore.PauseReason> = [.meeting, .micInUse, .screenSharing, .video, .fullscreen]
    private static let unboundedHolds: Set<PausaCore.PauseReason> = [.meeting, .micInUse, .screenSharing]

    /// After the scheduler has moved, so a break that just started ends the span at its start.
    /// Hours come from `isActive` directly, not from the phase: a meeting outside hours shows as .paused(.meeting).
    private func trackWork(now: Double, idle: Double, inHours: Bool,
                           pauseHolding: Bool, presenceHolding: Bool, unboundedHold: Bool) {
        let idleLimit = scheduler.config.idleFreezeThreshold
        var counting = inHours && !scheduler.isAway
        if case .onBreak = scheduler.phase { counting = false }

        if !presenceHolding && idle >= idleLimit && !recentAppSlices.isEmpty {
            let idleStart = now - idle
            for slice in recentAppSlices where slice.at >= idleStart {
                log.subtractAppUsage(bundleID: slice.bundleID, seconds: slice.seconds, on: slice.day)
            }
            recentAppSlices.removeAll(keepingCapacity: true)
        } else if idle < scheduler.config.typingIdle || presenceHolding {
            recentAppSlices.removeAll(keepingCapacity: true)
        }

        let activeWorking = counting && !pauseHolding && (presenceHolding || idle < idleLimit)
        if activeWorking {
            if let prev = lastAppSampleAt {
                let dt = min(max(0, now - prev), 5.0)
                if dt > 0, let app = frontmostAppProvider() {
                    lastActiveApp = app
                    let wall = clock.wallNow()
                    log.recordAppUsage(bundleID: app.bundleID, appName: app.name, seconds: dt, at: wall)
                    if !presenceHolding && idle >= scheduler.config.typingIdle {
                        recentAppSlices.append((at: now, day: cal.startOfDay(for: wall), bundleID: app.bundleID, seconds: dt))
                    }
                }
            } else if let app = frontmostAppProvider() {
                lastActiveApp = app
            }
            lastAppSampleAt = now
        } else {
            lastAppSampleAt = nil
        }

        let willKeepOpen = counting && (presenceHolding || idle < idleLimit)
        if work.openedAt != nil, willKeepOpen, openSpanIsHold != unboundedHold {
            if let closed = work.close(at: now) {
                log.append(span(closed, isHold: openSpanIsHold))
            }
        }

        let wasOpen = work.openedAt != nil
        if let s = work.update(now: now, counting: counting, holding: presenceHolding, inputIdle: idle, idleLimit: idleLimit) {
            log.append(span(s, isHold: openSpanIsHold))
            openSpanIsHold = false
            log.flushAppUsage(now: clock.wallNow())
        } else {
            if !wasOpen, work.openedAt != nil {
                openSpanIsHold = unboundedHold
            }
            if let open = work.openedAt, now - lastWorkCheckpoint >= Self.workCheckpointEvery {
                log.checkpoint(span((open, now), isHold: openSpanIsHold))
                log.flushAppUsage(now: clock.wallNow())
                lastWorkCheckpoint = now
            }
        }
    }

    /// 清除数据…: everything goes, and the span running now starts over from this moment.
    func clearStats() {
        log.clear()
        if work.openedAt != nil { _ = work.close(at: clock.continuousNow()) }
        openSpanIsHold = false
        lastWorkCheckpoint = 0
        lastAppSampleAt = nil
        lastActiveApp = nil
        breakTriggerApp = nil
        recentAppSlices.removeAll()
        onStatsChanged?()
    }

    /// The span running now, up to this moment (not in the log until it closes). For today's numbers.
    var openWorkSpan: WorkSpan? { work.openedAt.map { span(($0, clock.continuousNow()), isHold: openSpanIsHold) } }

    /// Lock, quit.
    func endWork() { endWork(at: clock.continuousNow()) }

    private func endWork(at now: Double) {
        lastAppSampleAt = nil
        recentAppSlices.removeAll()
        if let s = work.close(at: now) { log.append(span(s, isHold: openSpanIsHold)) }
        openSpanIsHold = false
        log.flushAppUsage(now: clock.wallNow())
    }

    /// Monotonic seconds to dates, through the current offset between the two clocks.
    private func span(_ s: (start: Double, end: Double), isHold: Bool = false) -> WorkSpan {
        let now = clock.continuousNow(), wall = clock.wallNow()
        return WorkSpan(start: wall.addingTimeInterval(s.start - now),
                        end: wall.addingTimeInterval(s.end - now),
                        isHold: isHold)
    }

    /// `chime: false` when coming back from a lock: a break that ran out meanwhile ends quietly.
    private func apply(_ cmds: [PausaCore.Command], chime chimes: Bool = true) {
        for c in cmds {
            defer { if chimes && showUI { chime.play(for: c, sound: settings.breakSound, reasons: chimeReasons) } }   // after the overlay is up
            switch c {
            case .showWarning:
                break   // 面板由 `effectivePreBreak` 驱动 (refreshPreBreak below); the menu bar icon reflects .warning on the next refresh
            case .recorded(let kind, let planned, let result):
                let wall = clock.wallNow()
                let skipApp = (result == .skipped) ? (breakTriggerApp ?? frontmostAppProvider() ?? lastActiveApp) : nil
                if result == .completed {
                    _ = log.redeemRecentSkip(by: kind, at: wall)
                }
                log.append(BreakRecord(start: breakStart ?? wall, kind: kind, planned: planned, result: result,
                                       appBundleID: skipApp?.bundleID, appName: skipApp?.name))
                log.flushAppUsage(now: wall)
                breakStart = nil
                breakTriggerApp = nil
                onStatsChanged?()
            case .startBreak(.short, let len):
                breakStart = clock.wallNow()
                breakTriggerApp = frontmostAppProvider() ?? lastActiveApp
                overlay.showShort(duration: len,
                                  holdDuration: scheduler.skipHoldDuration,
                                  onSkip: { [weak self] in self?.finish(.skipped) },
                                  onFinish: { [weak self] in self?.finish(.completed) })
            case .startBreak(.long, let len):
                breakStart = clock.wallNow()
                breakTriggerApp = frontmostAppProvider() ?? lastActiveApp
                overlay.showLong(duration: len,
                                 holdDuration: scheduler.skipHoldDuration,
                                 onSnooze: { [weak self] m in self?.snooze(minutes: m) },
                                 onSkip: { [weak self] in self?.finish(.skipped) },
                                 onFinish: { [weak self] in self?.finish(.completed) },
                                 can5: scheduler.canSnoozeOnBreak,
                                 show15: scheduler.postponeBudget(.long) >= Self.postponeLong,
                                 can15: scheduler.deferralLeft >= Self.postponeLong,
                                 mustNotDefer: scheduler.longMustNotDefer,
                                 onUrgent: { [weak self] in self?.urgentPause() })
            case .resumeBreak(.short, let left):
                overlay.showShort(duration: left,
                                  holdDuration: scheduler.skipHoldDuration,
                                  onSkip: { [weak self] in self?.finish(.skipped) },
                                  onFinish: { [weak self] in self?.finish(.completed) })
            case .resumeBreak(.long, let left):
                overlay.showLong(duration: left,
                                 holdDuration: scheduler.skipHoldDuration,
                                 onSnooze: { [weak self] m in self?.snooze(minutes: m) },
                                 onSkip: { [weak self] in self?.finish(.skipped) },
                                 onFinish: { [weak self] in self?.finish(.completed) },
                                 can5: scheduler.canSnoozeOnBreak,
                                 show15: scheduler.postponeBudget(.long) >= Self.postponeLong,
                                 can15: scheduler.deferralLeft >= Self.postponeLong,
                                 mustNotDefer: scheduler.longMustNotDefer,
                                 onUrgent: { [weak self] in self?.urgentPause() })
            case .endBreak:
                let wasPresenting = overlay.presentation.isPresenting
                overlay.dismiss()
                if !wasPresenting, !blocksRelaunch { onOverlayCleared?() }
            }
        }
        refreshPreBreak(immediate: cmds.contains { if case .startBreak = $0 { return true }; if case .resumeBreak = $0 { return true }; return false })
        onChange?()
    }

    /// Current pre-break UI state after masking user switches and suppressing while a full-screen preview is up.
    var effectivePreBreak: PreBreakState? {
        guard overlay.presentation != .preview else { return nil }
        return scheduler.preBreak?.masked(panel: settings.showPreBreakPanel, pointer: settings.showPreBreakPill)
    }

    /// Hand the scheduler's current pre-break state to the panel. A break that just started removes it at once;
    /// anything else retracts it. Manual pause, away, and `.preview` show nothing.
    private func refreshPreBreak(immediate: Bool = false) {
        guard showUI else { return }
        preBreak.update(effectivePreBreak, removal: immediate ? .immediate : .animated)
    }

    /// Wall-clock start of the break on screen, for its stats row (the scheduler runs on a monotonic clock).
    private var breakStart: Date?

    func finish(_ o: BreakOutcome) { apply(scheduler.finish(o, now: clock.continuousNow())) }

    /// Break screen 「休息延后 N 分钟」: a snooze brings the break back in snoozeLength (5 min);
    /// 15 adds the rest from the shared postpone allowance.
    func snooze(minutes: Int) {
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
            scheduler.enterAway(now: now)
            timer?.invalidate(); timer = nil
            overlay.dismiss(animated: false)
            if showUI { preBreak.update(nil, removal: .immediate) }
        case .end:
            let awaySecs: Double = switch scheduler.presence {
            case .away(_, let since): max(0, now - since)
            case .awaitingReturn(_, let bStart, _): max(0, now - bStart)
            case .active: 0
            }
            apply(scheduler.exitAway(.locked, now: now), chime: false)
            if awaySecs >= scheduler.config.shortLength {
                let kind: BreakKind = awaySecs >= scheduler.config.longLength ? .long : .short
                if log.redeemRecentSkip(by: kind, at: clock.wallNow()) {
                    onStatsChanged?()
                }
            }
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

    /// Settings "预览": 5 s of the long-break scene in explicit `.preview` mode. Never mutates `scheduler`,
    /// blocks Sparkle relaunches, suppresses pre-break panels while visible, and chimes only on natural completion.
    func previewLong() {
        if isOnBreak { return }
        overlay.showPreview(duration: 5, onFinish: { [weak self] in
            guard let self, self.showUI else { return }
            self.chime.play(for: .recorded(.long, planned: 5, .completed), sound: self.settings.breakSound, reasons: self.chimeReasons)
        })
        refreshPreBreak(immediate: true)
        onChange?()
        if showUI {
            chime.play(for: .startBreak(.long, length: 5), sound: settings.breakSound, reasons: chimeReasons)
        }
    }

    /// What the detector sees right now, unfiltered by the 自动暂停 switches: a call is a call.
    var chimeReasons: Set<PausaCore.PauseReason> { Set(rawReasons.map(\.core)) }

    /// Menu 暂停提醒: settles any active break (skip or urgent skip at the hard line) and enters `manualPause`
    /// bounded to the end of the current day (or at least 1 hour if clicked past 23:00).
    func pause() {
        let nowWall = clock.wallNow()
        let wallSecs = nowWall.timeIntervalSince1970
        let nextMidnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: nowWall))?.timeIntervalSince1970
        let untilWall = nextMidnight.map { max($0, wallSecs + 3600) }
        let cmds = scheduler.pauseManually(wallNow: wallSecs, untilWall: untilWall, now: clock.continuousNow())
        saveState()
        apply(cmds)
        overlay.dismiss()
        if showUI { preBreak.update(nil, removal: .animated) }
        onChange?()
    }

    /// 「紧急暂停提醒」 (long-break screen / pre-break panel, only at the hard line): end that long
    /// break as exactly one skip, then pause reminders as the menu does.
    func urgentPause() {
        let cmds = scheduler.urgentPause(now: clock.continuousNow(), wallNow: wallClock())
        saveState()
        apply(cmds)
        overlay.dismiss()
        if showUI { preBreak.update(nil, removal: .immediate) }
        onChange?()
    }

    func resume() {
        let cmds = scheduler.resumeManually(now: clock.continuousNow())
        saveState()
        apply(cmds)
        onChange?()
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
        switch scheduler.effectiveMode {
        case .manualPaused(let sinceWall, _):
            // 「提醒已暂停 2 小时 10 分钟」, whole minutes; under a minute just 「提醒已暂停」
            let minutes = (max(0, wallClock() - sinceWall) / 60).rounded(.down)
            return minutes < 1 ? L("status.paused") : L("status.pausedFor", StatsText.duration(minutes * 60))
        case .away:
            return L("status.away")
        case .autoPaused(.outsideHours):
            guard let next = nextWindowStart else { return L("status.outsideHours") }
            return L("status.nextStart", Self.whenText(next, cal: cal))
        case .autoPaused(let top):
            if let t = StatusPick.line(source: currentPauseSource?.statusText,
                                       autoStatus: autoPauseStatus?.title, reason: reasons[top]) { return t }
            let n = scheduler.next
            return L(n.kind == .long ? "status.longIn" : "status.shortIn", Self.clock(n.remaining))
        case .onBreak(let k, _, _):
            return k == .long ? L("status.onLongBreak") : L("status.onShortBreak")
        case .deferred, .warning, .working:
            if let t = StatusPick.line(source: nil, autoStatus: autoPauseStatus?.title, reason: nil) { return t }
            let n = scheduler.next
            return L(n.kind == .long ? "status.longIn" : "status.shortIn", Self.clock(n.remaining))
        }
    }

    /// Source holding the current pause (Mitchell: icon from `bundleID`). nil = not auto-paused.
    var currentPauseSource: PauseSource? {
        if case .autoPaused(let top) = scheduler.effectiveMode { return pauseSource(for: top) }
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
        switch scheduler.effectiveMode {
        case .manualPaused, .away, .autoPaused: return true
        case .onBreak, .warning, .deferred, .working: return false
        }
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
