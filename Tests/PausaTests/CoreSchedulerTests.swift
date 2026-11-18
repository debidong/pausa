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

    func testQuickLockNeverResetsUpcomingLongBreakAndIdleLockPreservesStart() {
        var s = Scheduler()
        // Advance past two short breaks and up to 90-min hard line with an upcoming long break.
        var t = 0.0
        while t < 3580 {
            _ = s.tick(now: t, reasons: [], inputIdle: 5)
            if case .onBreak(.short, _, _) = s.phase { _ = s.finish(.completed, now: t) }
            t += 1
        }
        XCTAssertEqual(s.next.kind, .long)
        XCTAssertLessThan(s.next.remaining, 30)

        // 20-second quick lock (< longLength) must NOT reset the upcoming long break to 20 minutes!
        s.enterAway(now: t)
        _ = s.exitAway(.locked, now: t + 25)
        XCTAssertEqual(s.next.kind, .long)
        XCTAssertEqual(s.next.remaining, s.config.returnCushion, accuracy: 2)

        // 15 minutes unengaged idle followed by 1 minute display lock counts as 16 minutes away -> full reset.
        var s2 = Scheduler()
        for sec in 0...1200 {
            _ = s2.tick(now: Double(sec), reasons: [], inputIdle: 1)
            if case .onBreak = s2.phase { _ = s2.finish(.completed, now: Double(sec)) }
        }
        for sec in 1201...2101 {
            _ = s2.tick(now: Double(sec), reasons: [], inputIdle: Double(sec - 1201))
        }
        XCTAssertTrue(s2.isAway)
        s2.enterAway(now: 2101)
        _ = s2.exitAway(.locked, now: 2161)
        XCTAssertEqual(s2.sinceLastLongBreak, 0, accuracy: 0.01)
        XCTAssertEqual(s2.cycle.index, 1)
    }

    func testPostBreakAwaitingReturnFreezesNextCycleAndUpgradesShortToLong() {
        var s = Scheduler()
        _ = s.breakNow(.short, now: 100)
        // User walked away 50s before the 20s short break started (inputIdle = 70 at end).
        let endCmds = s.tick(now: 120, reasons: [], inputIdle: 70)
        XCTAssertEqual(endCmds, [.recorded(.short, planned: 20, .completed), .endBreak])
        XCTAssertTrue(s.isAway)

        // 6 minutes pass without input: next cycle does not tick down while user is still away.
        for sec in 121...480 {
            XCTAssertEqual(s.tick(now: Double(sec), reasons: [], inputIdle: Double(70 + sec - 120)), [])
        }
        XCTAssertEqual(s.next.remaining, s.config.breakEvery, accuracy: 0.01)

        // Input returns after >= 5 minutes since break start -> upgraded to full long-break reset.
        _ = s.tick(now: 481, reasons: [], inputIdle: 0)
        XCTAssertFalse(s.isAway)
        XCTAssertEqual(s.sinceLastLongBreak, 0, accuracy: 0.01)
        XCTAssertEqual(s.cycle.index, 1)
    }

    func testDeferralConservationSnoozeHardLineGuardAndPartialRestCredit() {
        var s = Scheduler()
        var t = 0.0
        while t < 3590 {
            _ = s.tick(now: t, reasons: [], inputIdle: 5)
            if case .onBreak(.short, _, _) = s.phase { _ = s.finish(.completed, now: t) }
            t += 1
        }
        // Spend 15m of the 30m long deferral budget, then trigger the long break at 75m.
        XCTAssertTrue(s.postpone(by: 900))
        let spentBefore = s.config.longDeferBudget - s.deferralLeft
        XCTAssertEqual(spentBefore, 900, accuracy: 1)

        while t <= 4600 {
            _ = s.tick(now: t, reasons: [], inputIdle: 5)
            if case .onBreak(.long, _, _) = s.phase { break }
            t += 1
        }
        // Snoozing 5m must NOT wipe out the 15m deferral budget already spent!
        _ = s.finish(.snoozed, now: t + 1)
        XCTAssertEqual(s.config.longDeferBudget - s.deferralLeft, 900, accuracy: 2)

        // Advance to 88m (`sinceLongDone = 5280`) and start a long break: 5m snooze would cross 90m -> blocked!
        var s88 = Scheduler()
        s88.config.longEveryNth = 99
        for sec in 0..<5280 {
            _ = s88.tick(now: Double(sec), reasons: [], inputIdle: 5)
            if case .onBreak = s88.phase { _ = s88.finish(.completed, now: Double(sec)) }
        }
        _ = s88.breakNow(.long, now: 5280)
        XCTAssertFalse(s88.canSnoozeOnBreak)
        XCTAssertEqual(s88.finish(.snoozed, now: 5281), [])

        // Partial credit: resting 50% (150s of 300s) rolls back sitting time by 40% (`1 - 0.8 * 0.5 = 0.6`).
        _ = s88.finish(.skipped, now: 5280 + 150)
        XCTAssertEqual(s88.sinceLastLongBreak, 5280 * 0.6, accuracy: 5)

        // >= 80% rest (245s of 300s) settles as `.completed` and resets consecutive skips!
        _ = s88.breakNow(.long, now: 6000)
        let almostDone = s88.finish(.skipped, now: 6245)
        XCTAssertEqual(almostDone, [.recorded(.long, planned: 300, .completed), .endBreak])
        XCTAssertEqual(s88.consecutiveSkips, 0)
        XCTAssertEqual(s88.sinceLastLongBreak, 0, accuracy: 0.01)
    }

    func testProgressiveHoldDurationAndConsecutiveShortSkipEscalation() {
        var s = Scheduler()
        XCTAssertEqual(s.skipHoldDuration, 2.0, accuracy: 0.01)

        // Skip 1st short break via pre-break announcement -> holdDuration becomes 3.5s, next pre-break hides canSkip.
        for sec in 0...1180 { _ = s.tick(now: Double(sec), reasons: [], inputIdle: 5) }
        XCTAssertEqual(s.preBreak?.canSkip, true)
        XCTAssertEqual(s.skipUpcoming(now: 1180), [.recorded(.short, planned: 20, .skipped)])
        XCTAssertEqual(s.skipHoldDuration, 3.5, accuracy: 0.01)

        for sec in 1181...2360 { _ = s.tick(now: Double(sec), reasons: [], inputIdle: 5) }
        XCTAssertEqual(s.preBreak?.canSkip, false)
        XCTAssertEqual(s.skipUpcoming(now: 2360), [])   // consecutive pre-break skip refused

        // Start and skip 2nd short break -> holdDuration becomes 5.0s and cycle escalates straight to `.long`.
        for sec in 2361...2385 { _ = s.tick(now: Double(sec), reasons: [], inputIdle: 5) }
        _ = s.finish(.skipped, now: 2385)
        XCTAssertEqual(s.skipHoldDuration, 5.0, accuracy: 0.01)
        XCTAssertEqual(s.next.kind, .long)
        XCTAssertEqual(Scheduler.holdDuration(forConsecutiveSkips: 10), 8.0, accuracy: 0.01)
    }

    func testRhythmScoreV2PriorSmoothingPresetScalingAndHoldExemption() {
        let cal = Calendar(identifier: .gregorian)
        let day = Date(timeIntervalSince1970: 1_760_000_000)
        let dayStart = cal.startOfDay(for: day)

        // 1. Morning cold-start: 20m work + 1 skipped short break scores ~93 (no longer collapses to 74).
        let morningScore = Stats.computeRhythmScore(
            work: 20 * 60, taken: 0, skipped: 1, stretches: [20.0 * 60],
            weightedTaken: 0, weightedSkipped: 1, intervalMinutes: 20, hardLineMinutes: 90
        )
        XCTAssertEqual(morningScore, 93)

        // 2. Preset.gentle (40m interval) with 8 × 40m stretches and 0 skips scores 100!
        let gentleScore = Stats.computeRhythmScore(
            work: 8 * 40 * 60, taken: 8, skipped: 0,
            stretches: Array(repeating: 40.0 * 60, count: 8),
            weightedTaken: 12, weightedSkipped: 0, intervalMinutes: 40, hardLineMinutes: 90
        )
        XCTAssertEqual(gentleScore, 100)

        // 3. 2-hour auto-paused meeting (`isHold: true`) counts in total screen time without tanking rhythmScore.
        let spans = [
            WorkSpan(start: dayStart.addingTimeInterval(3600), end: dayStart.addingTimeInterval(3600 + 20 * 60)),
            WorkSpan(start: dayStart.addingTimeInterval(3600 + 20 * 60), end: dayStart.addingTimeInterval(3600 + 140 * 60), isHold: true),
        ]
        let breaks = [
            BreakRecord(start: dayStart.addingTimeInterval(3600 + 140 * 60), kind: .long, planned: 300, result: .completed),
        ]
        let d = Stats.days(breaks, work: spans, endingAt: dayStart.addingTimeInterval(6 * 3600), count: 1, calendar: cal)[0]
        XCTAssertEqual(d.work, 140 * 60, accuracy: 1)
        XCTAssertEqual(d.rhythmScore, 100)
    }
}
