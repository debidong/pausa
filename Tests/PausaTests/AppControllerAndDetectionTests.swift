import XCTest
@testable import Pausa
@testable import PausaCore

private final class MutableClock: @unchecked Sendable {
    var continuous: Double = 100
    var uptime: Double = 100
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
final class AppControllerAndDetectionTests: XCTestCase {
    private var tempDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        Settings.dryRun = false
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pausa-app-tests-\(UUID().uuidString)", isDirectory: true)
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

    func testTogglingPauseForMeetingsMidCallUpdatesSchedulerImmediatelyAndKeepsChimesMuted() {
        let clock = MutableClock()
        let settings = Settings(defaults: defaults)
        let log = BreakLog(url: tempDir.appendingPathComponent("breaks.jsonl"), now: clock.wall, ignoreDryRun: true)
        let app = AppController(
            settings: settings,
            detector: PauseDetector(defaults: defaults, clock: clock.pausaClock),
            log: log,
            clock: clock.pausaClock,
            defaults: defaults,
            inputIdle: { 5 },
            showUI: false
        )

        // Detector reports an active meeting while `pauseForMeetings` is ON (default).
        app.simulateReasons([.meeting])
        XCTAssertEqual(app.scheduler.phase, .paused(.meeting))
        XCTAssertTrue(app.chimeReasons.contains(.meeting))

        // User turns `pauseForMeetings` OFF mid-meeting: scheduler immediately resumes counting,
        // while `chimeReasons` still remembers `.meeting` so audio chimes stay silent during the call.
        settings.pauseForMeetings = false
        app.tick()
        XCTAssertEqual(app.scheduler.phase, .working)
        XCTAssertTrue(app.reasons.isEmpty)
        XCTAssertTrue(app.chimeReasons.contains(.meeting))

        // User turns `pauseForMeetings` back ON while still in the same meeting: pause returns at once.
        settings.pauseForMeetings = true
        app.tick()
        XCTAssertEqual(app.scheduler.phase, .paused(.meeting))
        XCTAssertNotNil(app.reasons[.meeting])
    }

    func testAwaySleepUsesContinuousClockAndClosesWorkSpan() {
        let clock = MutableClock()
        let settings = Settings(defaults: defaults)
        let log = BreakLog(url: tempDir.appendingPathComponent("breaks.jsonl"), now: clock.wall, ignoreDryRun: true)
        let app = AppController(
            settings: settings,
            detector: PauseDetector(defaults: defaults, clock: clock.pausaClock),
            log: log,
            clock: clock.pausaClock,
            defaults: defaults,
            inputIdle: { 1 },
            showUI: false
        )

        // Work for 10 minutes before sleeping.
        for _ in 0..<600 {
            app.tick()
            clock.advance(1)
        }
        XCTAssertGreaterThan(app.scheduler.sinceLastLongBreak, 590)

        // Mac sleeps for 15 minutes (`uptime` is frozen while `continuous` advances).
        app.handleAway(.start(.systemAsleep))
        clock.advance(15 * 60, sleeping: true)
        app.handleAway(.end(.systemAsleep))

        // Sleep >= longLength (5 min) resets the long-break clock and flushes the pre-sleep work span.
        XCTAssertLessThan(app.scheduler.sinceLastLongBreak, 2)
        let snap = log.snapshot(now: clock.wall)
        XCTAssertEqual(snap.work.count, 1)
        XCTAssertEqual(snap.work[0].end.timeIntervalSince(snap.work[0].start), 600, accuracy: 2)
    }

    func testManualPausePersistsAcrossControllerRestart() {
        let clock = MutableClock()
        let settings = Settings(defaults: defaults)
        let log = BreakLog(url: tempDir.appendingPathComponent("breaks.jsonl"), now: clock.wall, ignoreDryRun: true)

        do {
            let app1 = AppController(
                settings: settings,
                detector: PauseDetector(defaults: defaults, clock: clock.pausaClock),
                log: log,
                clock: clock.pausaClock,
                defaults: defaults,
                inputIdle: { 2 },
                showUI: false
            )
            app1.pause()
            XCTAssertTrue(app1.manualPaused)
            clock.advance(120)
            app1.tick()
            app1.saveState()
        }

        clock.advance(10)
        let app2 = AppController(
            settings: settings,
            detector: PauseDetector(defaults: defaults, clock: clock.pausaClock),
            log: log,
            clock: clock.pausaClock,
            defaults: defaults,
            inputIdle: { 2 },
            showUI: false
        )
        XCTAssertTrue(app2.manualPaused)
        app2.resume()
        XCTAssertFalse(app2.manualPaused)
    }

    func testScreenShareTrackerRequiresThreeSecondsAndActiveMeeting() {
        var tracker = ScreenShareMonitor.Tracker()
        XCTAssertFalse(tracker.acceptBrowserBar(seen: true, inMeeting: false, now: 10))
        XCTAssertNil(tracker.browserBarSince)

        XCTAssertFalse(tracker.acceptBrowserBar(seen: true, inMeeting: true, now: 10))
        XCTAssertFalse(tracker.acceptBrowserBar(seen: true, inMeeting: true, now: 12.9))
        XCTAssertTrue(tracker.acceptBrowserBar(seen: true, inMeeting: true, now: 13.0))

        // Disappearing bar resets persistence immediately.
        XCTAssertFalse(tracker.acceptBrowserBar(seen: false, inMeeting: true, now: 14.0))
        XCTAssertNil(tracker.browserBarSince)
    }

    func testCustomPauseAppMonitorDecodedCacheInvalidatesOnUpdate() throws {
        let first = [CustomPauseApp(bundleID: "com.apple.Safari", mode: .foreground)]
        defaults.set(try JSONEncoder().encode(first), forKey: DefaultsKey.customPauseApps)
        XCTAssertEqual(CustomPauseAppMonitor.load(defaults: defaults), first)

        let second = [
            CustomPauseApp(bundleID: "com.apple.dt.Xcode", mode: .running),
            CustomPauseApp(bundleID: "com.microsoft.VSCode", mode: .foregroundFullscreen),
        ]
        defaults.set(try JSONEncoder().encode(second), forKey: DefaultsKey.customPauseApps)
        XCTAssertEqual(CustomPauseAppMonitor.load(defaults: defaults), second)

        defaults.removeObject(forKey: DefaultsKey.customPauseApps)
        XCTAssertEqual(CustomPauseAppMonitor.load(defaults: defaults), [])
    }
}
