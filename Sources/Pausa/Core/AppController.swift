import AppKit
import Combine
import CoreGraphics
import PausaCore

/// Glue: detector + input idle + monotonic clock -> Scheduler -> overlay & menu bar.
/// Owns no policy of its own; every timing decision lives in PausaCore.Scheduler.
@MainActor
final class AppController {
    static let idleAwayThreshold: Double = 60   // stop counting work after 1 min without input

    private(set) var scheduler: PausaCore.Scheduler
    let detector = PauseDetector()
    let overlay = BreakOverlayController()
    let settings = Settings.shared
    private(set) var reasons: [PausaCore.PauseReason: String] = [:]   // reason -> display text
    private(set) var manualPauseUntil: Double?
    private var awaySince: Double?
    private var idleSince: Double?
    private var timer: Timer?
    private var bag: Set<AnyCancellable> = []
    var onChange: (() -> Void)?

    init() {
        scheduler = PausaCore.Scheduler(config: settings.config)
        detector.$reasons.sink { [weak self] r in self?.updateReasons(r) }.store(in: &bag)
        detector.onAway = { [weak self] e in self?.handleAway(e) }
        settings.onChange = { [weak self] c in self?.scheduler.config = c; self?.onChange?() }
    }

    func start() {
        detector.start()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
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

        let idle = Self.inputIdle()
        if !overlay.isShowing && idle >= Self.idleAwayThreshold {
            if idleSince == nil { idleSince = now - idle }
            return
        }
        if let since = idleSince {
            idleSince = nil
            scheduler.away(.idle, seconds: now - since, now: now)
        }
        apply(scheduler.tick(now: now, reasons: Set(reasons.keys), inputIdle: idle))
        onChange?()
    }

    private func apply(_ cmds: [PausaCore.Command]) {
        for c in cmds {
            switch c {
            case .showWarning:
                break   // menu bar icon reflects .warning on the next refresh
            case .startBreak(.short, let len):
                overlay.showShort(duration: len) { [weak self] in self?.finish(.completed) }
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
            idleSince = nil
            scheduler.away(.locked, seconds: secs, now: now)
        }
        onChange?()
    }

    // MARK: menu actions

    func breakNow() { apply(scheduler.breakNow(scheduler.next.kind, now: Self.now())) }

    func pauseForAnHour() {
        overlay.dismiss()
        if case .onBreak = scheduler.phase { _ = scheduler.finish(.skipped, now: Self.now()) }
        manualPauseUntil = Self.now() + 3600
        onChange?()
    }

    func resume() {
        manualPauseUntil = nil
        scheduler.away(.idle, seconds: 0, now: Self.now())   // resync clock, count nothing
        onChange?()
    }

    // MARK: what the menu shows

    var statusLine: String {
        if let until = manualPauseUntil {
            return "已暂停，\(Self.clock(until - Self.now())) 后恢复"
        }
        if awaySince != nil { return "你离开了电脑" }
        if case .paused(let top) = scheduler.phase, let text = reasons[top] { return "已暂停：\(text)" }
        if case .onBreak(let k, _) = scheduler.phase { return k == .long ? "长休息中" : "短休息中" }
        let n = scheduler.next
        return "\(n.kind == .long ? "长休息" : "短休息")：\(Self.clock(n.remaining)) 后"
    }

    var isPaused: Bool {
        if manualPauseUntil != nil || awaySince != nil { return true }
        if case .paused = scheduler.phase { return true }
        return false
    }

    static func clock(_ s: Double) -> String {
        let s = max(0, Int(s.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
