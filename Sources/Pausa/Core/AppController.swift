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
    private(set) var reasons: [PausaCore.PauseReason: String] = [:]   // reason -> display text
    private(set) var manualPauseUntil: Double?
    private var awaySince: Double?
    private var timer: Timer?
    private var bag: Set<AnyCancellable> = []
    private var hoursGate = HoursGate()
    private var boundaryTimer: Timer?
    /// Wall-clock calendar that follows time-zone / locale changes.
    private var cal: Calendar { Calendar.autoupdatingCurrent }
    var onChange: (() -> Void)?

    init() {
        scheduler = PausaCore.Scheduler(config: settings.config)
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

    // MARK: driving the scheduler

    private func tick() {
        let now = Self.now()
        if let until = manualPauseUntil {
            if now < until { return }
            resume()
        }
        if awaySince != nil { return }

        let active = !outsideHours
        if hoursGate.update(active) { scheduler.startFresh(now: now) }   // a window just opened
        var rs = Set(reasons.keys)
        if !active { rs.insert(.outsideHours) }

        let idle = Self.inputIdle()
        // No input is not rest: keep counting. A long stretch only offsets the long break.
        scheduler.away(.idle, seconds: idle, now: now)
        apply(scheduler.tick(now: now, reasons: rs, inputIdle: idle))
        onChange?()
    }

    private func apply(_ cmds: [PausaCore.Command]) {
        for c in cmds {
            switch c {
            case .showWarning:
                break   // menu bar icon reflects .warning on the next refresh
            case .startBreak(.short, let len):
                today.record(done: false)
                overlay.showShort(duration: len,
                                  onSkip: { [weak self] in self?.finish(.skipped) },
                                  onFinish: { [weak self] in self?.today.record(done: true); self?.finish(.completed) })
            case .startBreak(.long, let len):
                overlay.showLong(duration: len,
                                 onSnooze: { [weak self] in self?.finish(.snoozed) },
                                 onSkip: { [weak self] in self?.finish(.skipped) },
                                 onFinish: { [weak self] in self?.finish(.completed) })
            case .endBreak:
                overlay.dismiss()
            }
        }
        onChange?()
    }

    let today = DailyCount()

    private func finish(_ o: BreakOutcome) { apply(scheduler.finish(o, now: Self.now())) }

    private func updateReasons(_ r: Set<PauseReason>) {
        var m: [PausaCore.PauseReason: String] = [:]
        for x in r {
            switch x {
            case .meeting: m[.meeting] = x.displayText
            case .fullscreen: m[.fullscreen] = x.displayText
            }
        }
        reasons = m
        onChange?()
    }

    private func handleAway(_ e: PauseDetector.AwayEvent) {
        let now = Self.now()
        switch e {
        case .start:
            awaySince = now
            overlay.dismiss(animated: false)
        case .end:
            let secs = awaySince.map { now - $0 } ?? 0
            awaySince = nil
            scheduler.away(.locked, seconds: secs, now: now)
        }
        onChange?()
    }

    // MARK: menu actions

    func breakNow(_ kind: BreakKind) { apply(scheduler.breakNow(kind, now: Self.now())) }

    /// Settings "预览": 5 s of the long-break scene. Never touches the scheduler.
    func previewLong() {
        if case .onBreak = scheduler.phase { return }
        overlay.showLong(duration: 5, onSnooze: {}, onSkip: {})
    }

    func pauseForAnHour() {
        overlay.dismiss()
        if case .onBreak = scheduler.phase { _ = scheduler.finish(.skipped, now: Self.now()) }
        manualPauseUntil = Self.now() + 3600
        onChange?()
    }

    func resume() {
        manualPauseUntil = nil
        scheduler.resync(now: Self.now())   // the paused hour counts as nothing
        onChange?()
    }

    // MARK: what the menu shows

    var statusLine: String {
        if let until = manualPauseUntil {
            return L("已暂停，%@ 后恢复", Self.clock(until - Self.now()))
        }
        if awaySince != nil { return L("你离开了电脑") }
        if case .paused(.outsideHours) = scheduler.phase {
            guard let next = nextWindowStart else { return L("时段外") }
            return L("下次开始 %@", Self.whenText(next, cal: cal))
        }
        if case .paused(let top) = scheduler.phase, let text = reasons[top] { return L("已暂停：%@", text) }
        if case .onBreak(let k, _) = scheduler.phase { return k == .long ? L("长休息中") : L("短休息中") }
        let n = scheduler.next
        return L(n.kind == .long ? "长休息：%@ 后" : "短休息：%@ 后", Self.clock(n.remaining))
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

    static func clock(_ s: Double) -> String {
        let s = max(0, Int(s.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}


/// Today's short breaks: shown vs. completed. Local only, resets at midnight.
final class DailyCount {
    private let ud = UserDefaults.standard
    private func key() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "shortCount.\(c.year!)-\(c.month!)-\(c.day!)"
    }
    var counts: (done: Int, shown: Int) {
        let a = ud.array(forKey: key()) as? [Int] ?? [0, 0]
        return (a[0], a[1])
    }
    func record(done: Bool) {
        var (d, s) = counts
        if done { d += 1 } else { s += 1 }
        ud.set([d, s], forKey: key())
    }
    var line: String? {
        let (d, s) = counts
        return s == 0 ? nil : L("今天完成 %d/%d 次短休息", d, s)
    }
}
