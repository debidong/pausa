import XCTest
import Sparkle
@testable import Pausa
@testable import PausaCore

private final class TestClock: @unchecked Sendable {
    var continuous: Double = 1_000
    var uptime: Double = 1_000
    var wall: Date = Date(timeIntervalSince1970: 1_760_000_000)

    var pausaClock: PausaClock {
        PausaClock(
            continuousNow: { self.continuous },
            uptimeNow: { self.uptime },
            wallNow: { self.wall }
        )
    }

    func advance(_ seconds: Double, sleeping: Bool = false) {
        continuous += seconds
        if !sleeping { uptime += seconds }
        wall = wall.addingTimeInterval(seconds)
    }
}

@MainActor
final class ExplicitStateMachineTests: XCTestCase {
    private var tempDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        Settings.dryRun = false
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pausa-sm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let isolated = PausaDefaults.makeIsolated()
        defaults = isolated.defaults
        suiteName = isolated.suiteName
    }

    override func tearDownWithError() throws {
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    private func makeApp(clock: TestClock, inputIdle: @escaping () -> Double = { 10 }) -> AppController {
        let settings = Settings(defaults: defaults)
        let log = BreakLog(url: tempDir.appendingPathComponent("breaks.jsonl"), now: clock.wall, ignoreDryRun: true)
        return AppController(
            settings: settings,
            detector: PauseDetector(defaults: defaults, clock: clock.pausaClock),
            log: log,
            clock: clock.pausaClock,
            defaults: defaults,
            inputIdle: inputIdle,
            showUI: false
        )
    }

    // MARK: Design 1 — Scheduler Phase & DeferralSubstate

    func testTypingGraceSinceResetsAutomaticallyWhenInterruptedByPause() {
        var s = Scheduler()
        var t = 0.0
        while t < 1200 {
            _ = s.tick(now: t, reasons: [], inputIdle: 10)
            t += 1
        }
        // At t = 1200 the short break is due while actively typing (inputIdle = 0).
        XCTAssertEqual(s.tick(now: 1200, reasons: [], inputIdle: 0), [])
        XCTAssertEqual(s.phase, .deferred(.short, .typingGrace(since: 1200)))
        XCTAssertEqual(s.preBreak?.typingWait, true)

        // Advance 20 s inside the 30 s `Config.typingGrace` window; `since` stays anchored at 1200.
        for sec in 1201...1220 {
            XCTAssertEqual(s.tick(now: Double(sec), reasons: [], inputIdle: 0), [])
        }
        XCTAssertEqual(s.phase, .deferred(.short, .typingGrace(since: 1200)))

        // Transitioning through `.paused` destroys the associated `typingGrace(since: 1200)`.
        XCTAssertEqual(s.tick(now: 1221, reasons: [.outsideHours], inputIdle: 0), [])
        XCTAssertEqual(s.phase, .paused(.outsideHours))
        XCTAssertNil(s.preBreak)

        // Returning with `inputIdle = 0` starts a fresh 30 s typingGrace window at 1222,
        // surviving well past 1230 (where a stale `since = 1200` would have expired) until 1252.
        XCTAssertEqual(s.tick(now: 1222, reasons: [], inputIdle: 0), [])
        XCTAssertEqual(s.phase, .deferred(.short, .typingGrace(since: 1222)))
        for sec in 1223...1251 {
            XCTAssertEqual(s.tick(now: Double(sec), reasons: [], inputIdle: 0), [])
        }
        XCTAssertEqual(s.tick(now: 1252, reasons: [], inputIdle: 0), [.startBreak(.short, length: 20)])
    }

    func testDeferredSourceProjectsDeferringAndPostponeExitsToWorking() {
        var s = Scheduler()
        for sec in 0..<1200 {
            _ = s.tick(now: Double(sec), reasons: [], inputIdle: 10)
        }
        XCTAssertEqual(s.tick(now: 1200, reasons: [], deferrals: [.focusApp()], inputIdle: 10), [])
        XCTAssertEqual(s.phase, .deferred(.short, .source(.focusApp)))
        XCTAssertEqual(s.deferring, .focusApp)
        XCTAssertNil(s.preBreak)

        XCTAssertTrue(s.postpone(by: 300))
        XCTAssertEqual(s.phase, .working)
        XCTAssertNil(s.deferring)
    }

    // MARK: Design 2 — Presence × ManualPauseState × EffectiveMode & Migration

    func testManualPausePlusShortLockFreezesHardLineCounter() {
        let clock = TestClock()
        let app = makeApp(clock: clock, inputIdle: { 2 })

        // Accumulate 10 minutes of active work before manual pause.
        for _ in 0..<600 {
            app.tick()
            clock.advance(1)
        }
        let baseline = app.scheduler.sinceLastLongBreak
        XCTAssertEqual(baseline, 599, accuracy: 2)

        app.pause()
        XCTAssertTrue(app.manualPaused)
        if case .manualPaused(_, let isAway) = app.scheduler.effectiveMode {
            XCTAssertFalse(isAway)
        } else {
            XCTFail("Expected manualPaused effective mode")
        }

        // Lock screen for 3 minutes (< longLength of 5 min). Even if `tick()` fires while locked,
        // `sinceLastLongBreak` must stay completely frozen.
        app.handleAway(.start(.screenLocked))
        if case .manualPaused(_, let isAway) = app.scheduler.effectiveMode {
            XCTAssertTrue(isAway)
        } else {
            XCTFail("Expected manualPaused(isAway: true)")
        }

        let beforeLockCounter = app.scheduler.sinceLastLongBreak
        for _ in 0..<180 {
            clock.advance(1)
            app.tick()
        }
        app.handleAway(.end(.screenLocked))

        XCTAssertTrue(app.manualPaused)
        XCTAssertEqual(app.scheduler.sinceLastLongBreak, beforeLockCounter, accuracy: 0.001)
    }

    func testManualPausePlusLongLockResetsHardLineCounterWithoutEndingManualPause() {
        let clock = TestClock()
        let app = makeApp(clock: clock, inputIdle: { 2 })

        for _ in 0..<1200 {
            app.tick()
            clock.advance(1)
        }
        app.pause()
        XCTAssertGreaterThan(app.scheduler.sinceLastLongBreak, 1100)

        app.handleAway(.start(.screenLocked))
        clock.advance(6 * 60, sleeping: true)
        app.handleAway(.end(.screenLocked))

        XCTAssertTrue(app.manualPaused)
        XCTAssertEqual(app.scheduler.sinceLastLongBreak, 0, accuracy: 0.001)
    }

    func testLegacyManualPauseDefaultsMigrateIntoSchedulerSavedAndRemoveLegacyKeys() {
        let clock = TestClock()
        let legacySince = clock.wall.addingTimeInterval(-600).timeIntervalSince1970
        defaults.set(true, forKey: DefaultsKey.manualPaused)
        defaults.set(legacySince, forKey: DefaultsKey.manualPausedSince)

        let app1 = makeApp(clock: clock)
        XCTAssertTrue(app1.manualPaused)
        XCTAssertEqual(app1.manualPausedSince?.timeIntervalSince1970 ?? 0, legacySince, accuracy: 0.001)
        XCTAssertNil(defaults.object(forKey: DefaultsKey.manualPaused))
        XCTAssertNil(defaults.object(forKey: DefaultsKey.manualPausedSince))

        // Subsequent launch reads manual pause atomically from Scheduler.Saved alone.
        clock.advance(30)
        let app2 = makeApp(clock: clock)
        XCTAssertTrue(app2.manualPaused)
        XCTAssertEqual(app2.manualPausedSince?.timeIntervalSince1970 ?? 0, legacySince, accuracy: 0.001)
    }

    // MARK: Design 3 — BreakOverlayController Presentation & .preview Coordination

    func testPreviewBlocksRelaunchSuppressesPreBreakAndNotifiesOnCompletion() {
        let clock = TestClock()
        let app = makeApp(clock: clock)

        // Advance into the 30 s pre-break warning window (t = 1180 => 20 s remaining).
        for _ in 0...1180 {
            app.tick()
            clock.advance(1)
        }
        XCTAssertNotNil(app.effectivePreBreak)
        XCTAssertFalse(app.blocksRelaunch)

        var clearedCount = 0
        app.onOverlayCleared = { clearedCount += 1 }

        app.previewLong()
        XCTAssertEqual(app.overlay.presentation, .preview)
        XCTAssertTrue(app.blocksRelaunch)
        XCTAssertFalse(app.isOnBreak)
        XCTAssertNil(app.effectivePreBreak)

        // Natural 5 s completion restores pre-break UI and fires `onOverlayCleared` once.
        app.overlay.completeCurrentSessionForTesting()
        XCTAssertEqual(app.overlay.presentation, .hidden)
        XCTAssertFalse(app.blocksRelaunch)
        XCTAssertNotNil(app.effectivePreBreak)
        XCTAssertEqual(clearedCount, 1)
    }

    func testRealBreakPreemptsActivePreviewWithoutIntermediateClearance() {
        let clock = TestClock()
        let app = makeApp(clock: clock)

        var clearedCount = 0
        app.onOverlayCleared = { clearedCount += 1 }

        app.previewLong()
        XCTAssertEqual(app.overlay.presentation, .preview)

        // Preempting `.preview` with `.shortBreak` must not dip through `.hidden` or release held updates early.
        app.breakNow(.short)
        XCTAssertEqual(app.overlay.presentation, .shortBreak)
        XCTAssertTrue(app.isOnBreak)
        XCTAssertTrue(app.blocksRelaunch)
        XCTAssertEqual(clearedCount, 0)

        // Skipping the real break finally clears the overlay and notifies once.
        app.overlay.skipCurrentSessionForTesting()
        XCTAssertEqual(app.overlay.presentation, .hidden)
        XCTAssertFalse(app.isOnBreak)
        XCTAssertFalse(app.blocksRelaunch)
        XCTAssertEqual(clearedCount, 1)
    }

    // MARK: Design 4 — UpdateStateMachine & Single-Track Updater Coordination

    func testUpdateStateMachinePreservesUpToDateOnDismissAndClearsOnInfoOnly() {
        var sm = UpdateStateMachine()
        XCTAssertEqual(sm.phase, .idle)

        XCTAssertEqual(sm.send(.checkStarted), .checking)
        XCTAssertEqual(sm.send(.notFound), .upToDate)
        // Sparkle always calls `dismissUpdateInstallation` at the end of a no-update check.
        XCTAssertEqual(sm.send(.sessionDismissed), .upToDate)

        // A later background info-only item resets phase cleanly to `.idle` (no stale `.upToDate`).
        XCTAssertEqual(sm.send(.updateFound(version: "0.7.0", alreadyDownloaded: false, infoOnly: true)), .idle)
        XCTAssertEqual(sm.send(.sessionDismissed), .idle)
    }

    func testUpdaterHoldsReadyInstallDuringPreviewAndProceedsWhenPreviewClears() {
        let clock = TestClock()
        let app = makeApp(clock: clock)
        let updater = Updater()
        let model = UpdateModel()

        var relaunchSaves = 0
        updater.canInstallNow = { !app.blocksRelaunch }
        updater.willRelaunch = { relaunchSaves += 1 }
        app.onOverlayCleared = { updater.retryHeldInstall() }
        model.bind(updater)

        updater.driver.onUserCheckStarted?()
        XCTAssertEqual(model.phase, .checking)

        updater.driver.onUpdateFound?("0.6.3", false, false)
        XCTAssertEqual(model.phase, .downloading(version: "0.6.3"))

        // User opens 5 s full-screen preview right before download finishes extracting.
        app.previewLong()
        XCTAssertTrue(app.blocksRelaunch)

        var chosen: SPUUserUpdateChoice?
        updater.driver.onReadyToInstall? { choice in chosen = choice }
        XCTAssertEqual(model.phase, .readyToInstall(version: "0.6.3"))
        XCTAssertEqual(model.readyVersion, "0.6.3")
        XCTAssertNil(chosen)
        XCTAssertEqual(relaunchSaves, 0)

        // Preview finishes -> `onOverlayCleared` releases the held install automatically.
        app.overlay.completeCurrentSessionForTesting()
        XCTAssertEqual(chosen, .install)
        XCTAssertEqual(relaunchSaves, 1)
        XCTAssertEqual(model.phase, .installing(version: "0.6.3"))
    }

    func testUpdaterAbortErrorReachesUpdateModel() {
        let updater = Updater()
        let model = UpdateModel()
        model.bind(updater)

        updater.driver.onUserCheckStarted?()
        XCTAssertEqual(model.phase, .checking)

        updater.driver.onError?("Feed unreachable")
        XCTAssertEqual(model.phase, .failed(message: "Feed unreachable"))
        XCTAssertEqual(model.statusText, L("update.failed"))

        // Session dismissal keeps `.failed` visible for Settings -> About.
        updater.driver.onDismissed?()
        XCTAssertEqual(model.phase, .failed(message: "Feed unreachable"))
    }
}
