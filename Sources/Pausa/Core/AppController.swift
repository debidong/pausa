import AppKit
import Combine
import CoreGraphics
import PausaCore

/// Glue: detector + input idle + monotonic clock -> Scheduler -> overlay & menu bar.
/// Owns no policy of its own; every timing decision lives in PausaCore.Scheduler.
@MainActor
final class AppController {
    private(set) var scheduler: PausaCore.Scheduler
    let detector = PauseDetector()
    let overlay = BreakOverlayController()
    let settings = Settings.shared
    private var pauseCap = PauseCap()
    private(set) var reasons: [PausaCore.PauseReason: String] = [:]   // reason -> full 「已暂停：…」 line
    private(set) var manualPauseUntil: Double?
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

    init() {
        scheduler = PausaCore.Scheduler(config: settings.config)
        restoreState()
        detector.$reasons.sink { [weak self] r in self?.updateReasons(r) }.store(in: &bag)
        detector.onAway = { [weak self] e in self?.handleAway(e) }
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

    var outsideHours: Bool { !isActive(settings.schedule, at: Date(), cal: cal) }

    /// Next window start, for the menu ("下次开始 9:00"). nil when the schedule is off.
    var nextWindowStart: Date? { outsideHours ? nextStart(settings.schedule, after: Date(), cal: cal) : nil }

    private func scheduleChanged() {
        armBoundaryTimer()
        tick()
    }

    /// One-shot timer at the next window edge so the switch is exact even if ticks are coalesced.
    private func armBoundaryTimer() {
        boundaryTimer?.invalidate(); boundaryTimer = nil
        guard let at = nextChange(settings.schedule, after: Date(), cal: cal) else { return }
        let t = Timer(fire: at.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleChanged() }
        }
        RunLoop.main.add(t, forMode: .common)
        boundaryTimer = t
    }

    func start() {
        detector.start()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
        armBoundaryTimer()
        tick()
    }

    /// Monotonic seconds that keep counting while the Mac sleeps.
    static func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }

    static func inputIdle() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: persistence (time since last long break, shared defer budget, 90-minute line)

    private static let stateKey = "scheduler.state"

    /// Wall clock for the quit-to-launch gap (monotonic time restarts with the process).
    private static func wallClock() -> Double { Date().timeIntervalSince1970 }

    private func restoreState() {
        guard !Settings.dryRun,
              let data = UserDefaults.standard.data(forKey: Self.stateKey),
              let saved = try? JSONDecoder().decode(PausaCore.Scheduler.Saved.self, from: data) else { return }
        scheduler.restore(saved, wallClock: Self.wallClock(), now: Self.now())
    }

    /// Called every minute from tick(), on quit, and right before an update relaunch.
    func saveState() {
        guard !Settings.dryRun,
              let data = try? JSONEncoder().encode(scheduler.saved(wallClock: Self.wallClock())) else { return }
        UserDefaults.standard.set(data, forKey: Self.stateKey)
        lastSave = Self.now()
    }

    /// True while a break is on screen: update installs wait until it ends.
    var isOnBreak: Bool { if case .onBreak = scheduler.phase { return true }; return false }

    // MARK: driving the scheduler

    private func tick() {
        let now = Self.now()
        if now - lastSave >= 60 { saveState() }
        if let until = manualPauseUntil {
            if now < until {
                let idle = Self.inputIdle()
                scheduler.manualPauseTick(now: now, inputIdle: idle)
                trackWork(now: now, idle: idle, inHours: awaySince == nil && !outsideHours, holding: false)   // 暂停 1 小时 is still work; a lock is not
                return
            }
            resume()
            return
        }
        if awaySince != nil { return }

        let active = !outsideHours
        if hoursGate.update(active) { scheduler.startFresh(now: now) }   // a window just opened
        var rs = pauseCap.filter(Set(reasons.keys), now: now)   // 2 h cap (video/fullscreen drop)
        if !active { rs.insert(.outsideHours) }

        let idle = Self.inputIdle()
        // No input is not rest: keep counting. A long stretch only offsets the long break.
        scheduler.away(.idle, seconds: idle, now: now)
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

    private static let holds: Set<PausaCore.PauseReason> = [.meeting, .screenSharing, .video, .fullscreen]

    /// After the scheduler has moved, so a break that just started ends the span at its start.
    /// Hours come from `isActive` directly, not from the phase: a meeting outside hours shows as .paused(.meeting).
    private func trackWork(now: Double, idle: Double, inHours: Bool, holding: Bool) {
        var counting = inHours
        if case .onBreak = scheduler.phase { counting = false }
        if let s = work.update(now: now, counting: counting, holding: holding, inputIdle: idle, idleLimit: scheduler.config.longLength) {
            BreakLog.shared.append(span(s))
        } else if let open = work.openedAt, now - lastWorkCheckpoint >= Self.workCheckpointEvery {
            BreakLog.shared.checkpoint(span((open, now)))
            lastWorkCheckpoint = now
        }
    }

    /// 清除数据…: everything goes, and the span running now starts over from this moment.
    func clearStats() {
        BreakLog.shared.clear()
        if work.openedAt != nil { _ = work.close(at: Self.now()) }
        lastWorkCheckpoint = 0
        onStatsChanged?()
    }

    /// The span running now, up to this moment (not in the log until it closes). For today's numbers.
    var openWorkSpan: WorkSpan? { work.openedAt.map { span(($0, Self.now())) } }

    /// Lock, quit.
    func endWork() { endWork(at: Self.now()) }

    private func endWork(at now: Double) {
        if let s = work.close(at: now) { BreakLog.shared.append(span(s)) }
    }

    /// Monotonic seconds to dates, through the current offset between the two clocks.
    private func span(_ s: (start: Double, end: Double)) -> WorkSpan {
        let now = Self.now(), wall = Date()
        return WorkSpan(start: wall.addingTimeInterval(s.start - now), end: wall.addingTimeInterval(s.end - now))
    }

    private func apply(_ cmds: [PausaCore.Command]) {
        for c in cmds {
            switch c {
            case .showWarning:
                break   // menu bar icon reflects .warning on the next refresh
            case .recorded(let kind, let planned, let result):
                BreakLog.shared.append(BreakRecord(start: breakStart ?? Date(), kind: kind, planned: planned, result: result))
                breakStart = nil
                onStatsChanged?()
            case .startBreak(.short, let len):
                breakStart = Date()
                overlay.showShort(duration: len,
                                  onSkip: { [weak self] in self?.finish(.skipped) },
                                  onFinish: { [weak self] in self?.finish(.completed) })
            case .startBreak(.long, let len):
                breakStart = Date()
                overlay.showLong(duration: len,
                                 onSnooze: { [weak self] m in self?.snooze(minutes: m) },
                                 onSkip: { [weak self] in self?.finish(.skipped) },
                                 onFinish: { [weak self] in self?.finish(.completed) },
                                 show15: scheduler.postponeBudget(.long) >= Self.postponeLong,
                                 can15: scheduler.deferralLeft >= Self.postponeLong,
                                 mustNotDefer: scheduler.longMustNotDefer)
            case .resumeBreak(.short, let left):
                overlay.showShort(duration: left,
                                  onSkip: { [weak self] in self?.finish(.skipped) },
                                  onFinish: { [weak self] in self?.finish(.completed) })
            case .resumeBreak(.long, let left):
                overlay.showLong(duration: left,
                                 onSnooze: { [weak self] m in self?.snooze(minutes: m) },
                                 onSkip: { [weak self] in self?.finish(.skipped) },
                                 onFinish: { [weak self] in self?.finish(.completed) },
                                 show15: scheduler.postponeBudget(.long) >= Self.postponeLong,
                                 can15: scheduler.deferralLeft >= Self.postponeLong,
                                 mustNotDefer: scheduler.longMustNotDefer)
            case .endBreak:
                overlay.dismiss()
                onBreakEnded?()
            }
        }
        onChange?()
    }

    /// Wall-clock start of the break on screen, for its stats row (the scheduler runs on a monotonic clock).
    private var breakStart: Date?

    private func finish(_ o: BreakOutcome) { apply(scheduler.finish(o, now: Self.now())) }

    /// Break screen 「休息延后 N 分钟」: a snooze brings the break back in snoozeLength (5 min);
    /// 15 adds the rest from the shared postpone allowance.
    private func snooze(minutes: Int) {
        finish(.snoozed)
        let extra = Double(minutes) * 60 - scheduler.config.snoozeLength
        if extra > 0, scheduler.canPostpone(by: extra) { postpone(by: extra) }
    }

#if DEBUG
    /// Debug (`--capture-menu --meeting`): pretend the detector reported these reasons.
    func simulateReasons(_ r: Set<PauseReason>) { updateReasons(r); tick() }
#endif

    private func updateReasons(_ r: Set<PauseReason>) {
        var m: [PausaCore.PauseReason: String] = [:]
        for x in r {
            if case .meeting = x, !settings.pauseForMeetings { continue }   // 自动暂停 → 开会时 off
            switch x {
            case .meeting, .fullscreen: m[x.core] = x.pausedText
            default: if m[x.core] == nil { m[x.core] = x.pausedText }   // Linus: video / share / recording
            }
        }
        reasons = m
        onChange?()
    }

    private func handleAway(_ e: PauseDetector.AwayEvent) {
        let now = Self.now()
        switch e {
        case .start:
            endWork(at: now)
            awaySince = now
            overlay.dismiss(animated: false)
        case .end:
            let secs = awaySince.map { now - $0 } ?? 0
            awaySince = nil
            apply(scheduler.away(.locked, seconds: secs, now: now))
        }
        onChange?()
    }

    // MARK: menu actions

    func breakNow(_ kind: BreakKind) { apply(scheduler.breakNow(kind, now: Self.now())) }

    /// Popover +5分 / +15分: push the next break back within the shared budget (greyed out otherwise).
    func postpone(by seconds: Double) { scheduler.postpone(by: seconds); onChange?() }

    /// Settings "预览": 5 s of the long-break scene. Never touches the scheduler.
    func previewLong() {
        if case .onBreak = scheduler.phase { return }
        overlay.showLong(duration: 5, onSnooze: { _ in }, onSkip: {})
    }

    func pauseForAnHour() {
        if case .onBreak = scheduler.phase {
            // Past the 90-minute line the long break can't be skipped, so it can't be paused away.
            let cmds = scheduler.finish(.skipped, now: Self.now())
            if cmds.isEmpty { return }
            apply(cmds)   // records the skip
        }
        overlay.dismiss()
        manualPauseUntil = Self.now() + 3600
        onChange?()
    }

    func resume() {
        manualPauseUntil = nil
        // Round 7b: the pause counted toward the 90-minute line; past it, the long break starts now.
        apply(scheduler.manualPauseEnded(now: Self.now()))
        onChange?()
    }

    // MARK: what the menu shows

    /// v2 status (§6.2) for AutoPauseStatus: hold reasons first, then the active deferral.
    var autoPauseStatus: AutoPauseStatus? {
        if case .paused(let top) = scheduler.phase {
            for r in detector.reasons where r.core == top {
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
        case .focusApp?:
            let m = Int((scheduler.deferralLeft(for: .focusApp, cap: Deferral.focusApp().cap) / 60).rounded(.up))
            return .customApp(app: detector.customAppName ?? "", minutesLeft: m)
        case .focusMode?: return .focus(name: nil, scope: settings.focusModeScope)
        case nil: return nil
        }
    }

    var statusLine: String {
        if let until = manualPauseUntil {
            return L("已暂停，%@ 后恢复", Self.clock(until - Self.now()))
        }
        if awaySince != nil { return L("你离开了电脑") }
        if case .paused(.outsideHours) = scheduler.phase {
            guard let next = nextWindowStart else { return L("时段外") }
            return L("下次开始 %@", Self.whenText(next, cal: cal))
        }
        var reasonText: String?
        if case .paused(let top) = scheduler.phase { reasonText = reasons[top] }
        if let t = StatusPick.line(source: currentPauseSource?.statusText,
                                   autoStatus: autoPauseStatus?.title, reason: reasonText) { return t }
        if case .onBreak(let k, _) = scheduler.phase { return k == .long ? L("长休息中") : L("短休息中") }
        let n = scheduler.next
        return L(n.kind == .long ? "长休息：%@ 后" : "短休息：%@ 后", Self.clock(n.remaining))
    }

    /// Source holding the current pause (Mitchell: icon from `bundleID`). nil = not auto-paused.
    var currentPauseSource: PauseSource? {
        if case .paused(let top) = scheduler.phase { return pauseSource(for: top) }
        return nil
    }
    private func pauseSource(for r: PausaCore.PauseReason) -> PauseSource? {
        if let s = detector.sources[r] { return s }
        switch r {   // reason without detector data (e.g. debug simulate): text only
        case .meeting: return PauseSource(kind: .meeting)
        default: return nil
        }
    }

    var isPaused: Bool {
        if manualPauseUntil != nil || awaySince != nil { return true }
        if case .paused = scheduler.phase { return true }
        return false
    }

    /// "9:00" today, "明天 9:00" tomorrow, else "周一 9:00" (app language).
    static func whenText(_ d: Date, cal: Calendar) -> String {
        let f = DateFormatter(); f.locale = AppLanguage.current.locale
        f.setLocalizedDateFormatFromTemplate("Hmm")
        let time = f.string(from: d)
        if cal.isDateInToday(d) { return time }
        if cal.isDateInTomorrow(d) { return L("明天 %@", time) }
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


