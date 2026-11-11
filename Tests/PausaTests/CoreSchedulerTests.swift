import XCTest
@testable import PausaCore

final class CoreSchedulerTests: XCTestCase {
    private func run(_ s: inout Scheduler, from: Double, to: Double,
                     reasons: Set<PauseReason> = [], deferrals: [Deferral] = [],
                     idle: Double = 10) -> [Command] {
        var out: [Command] = []
        var t = from
        while t <= to {
            out += s.tick(now: t, reasons: reasons, deferrals: deferrals, inputIdle: idle)
            t += 1
        }
        return out
    }

    func testShortAndLongBreakCycle() {
        var s = Scheduler()
        var t = 0.0
        var starts: [BreakKind] = []
        while t <= 3700 {
            for c in s.tick(now: t, reasons: [], inputIdle: 10) {
                if case .startBreak(let k, _) = c { starts.append(k) }
            }
            if case .onBreak = s.phase { _ = s.finish(.completed, now: t) }
            t += 1
        }
        XCTAssertEqual(starts, [.short, .short, .long])
    }

    func testHardLineRefusesSkipAndAllowsUrgentExit() {
        var c = Config()
        c.hardLine = 60 * 60
        var s = Scheduler(config: c)
        _ = run(&s, from: 0, to: 4200, reasons: [.meeting])
        XCTAssertTrue(s.longMustNotDefer)

        let startCmds = s.tick(now: 4201, reasons: [], inputIdle: 10)
        XCTAssertEqual(startCmds, [.startBreak(.long, length: c.longLength)])
        XCTAssertEqual(s.finish(.skipped, now: 4202), [])
        XCTAssertEqual(s.finish(.snoozed, now: 4202), [])

        let urgent = s.urgentPause(now: 4203)
        XCTAssertEqual(urgent, [.recorded(.long, planned: 300, .skipped), .endBreak])
        XCTAssertTrue(s.longMustNotDefer)
    }

    func testPersistenceRoundTripAndRestGap() {
        var s = Scheduler()
        _ = run(&s, from: 0, to: 600)
        XCTAssertTrue(s.postpone(by: 300))
        let saved = s.saved(wallClock: 1_000_000)

        var quickRestart = Scheduler()
        quickRestart.restore(saved, wallClock: 1_000_010, now: 50)
        XCTAssertEqual(quickRestart.sinceLastLongBreak, s.sinceLastLongBreak, accuracy: 0.01)
        XCTAssertEqual(quickRestart.deferralLeft, s.deferralLeft, accuracy: 0.01)

        var restedRestart = Scheduler()
        restedRestart.restore(saved, wallClock: 1_000_000 + 6 * 60, now: 0)
        XCTAssertEqual(restedRestart.sinceLastLongBreak, 0)
        XCTAssertEqual(restedRestart.cycle.index, 1)
    }

    func testScheduleCrossMidnightAndDayOverrides() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
        }

        var sch = PausaSchedule(enabled: true, rules: [
            PausaWindow(start: ClockTime(9), end: ClockTime(18), weekdays: [2, 3, 4, 5, 6]),
            PausaWindow(start: ClockTime(22), end: ClockTime(2), weekdays: [6]),
        ])
        XCTAssertTrue(isActive(sch, at: at(2026, 10, 16, 23, 30), cal: cal))
        XCTAssertTrue(isActive(sch, at: at(2026, 10, 17, 1, 30), cal: cal))
        XCTAssertFalse(isActive(sch, at: at(2026, 10, 17, 2, 0), cal: cal))

        sch.days[DateKey(y: 2026, m: 10, d: 10)] = .work   // Saturday make-up workday
        sch.days[DateKey(y: 2026, m: 10, d: 12)] = .off    // Monday holiday
        XCTAssertTrue(isActive(sch, at: at(2026, 10, 10, 10, 0), cal: cal))
        XCTAssertFalse(isActive(sch, at: at(2026, 10, 12, 10, 0), cal: cal))
    }

    func testCallHoldAndPauseCap() {
        var hold = CallHold()
        for t in 0..<60 {
            let st = hold.update(micOn: true, meetingAppMic: false, camera: false, now: Double(t))
            XCTAssertNil(st.reason)
            XCTAssertTrue(st.micPending)
        }
        let held = hold.update(micOn: true, meetingAppMic: false, camera: false, now: 60)
        XCTAssertEqual(held.reason, .micInUse)
        XCTAssertFalse(held.micPending)

        var cap = PauseCap()
        XCTAssertEqual(cap.filter([.video, .meeting], now: 0), [.video, .meeting])
        XCTAssertEqual(cap.filter([.video, .meeting], now: PauseCap.defaultCap), [.meeting])
    }

    func testWorkClockAndChimeRules() {
        var w = WorkClock()
        XCTAssertNil(w.update(now: 0, counting: true, inputIdle: 0, idleLimit: 300))
        let span = w.update(now: 1000, counting: true, inputIdle: 300, idleLimit: 300)
        XCTAssertEqual(span?.start ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(span?.end ?? -1, 700, accuracy: 0.01)

        XCTAssertEqual(Chime.pick(.startBreak(.long, length: 300), sound: .longOnly, reasons: []), .longStart)
        XCTAssertNil(Chime.pick(.startBreak(.long, length: 300), sound: .all, reasons: [.meeting]))
        XCTAssertEqual(Chime.pick(.startBreak(.short, length: 20), sound: .all, reasons: [.video]), .shortStart)
    }

    func testPhotoContrastExtraDim() {
        XCTAssertEqual(PhotoContrast.extraDim(y95: 0.9399), 0.53)
        XCTAssertEqual(PhotoContrast.extraDim(y95: 0.0135), 0)
        XCTAssertEqual(PhotoContrast.percentile95((1...100).map(Double.init)), 95)
    }
}
