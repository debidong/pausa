import XCTest
@testable import Pausa
@testable import PausaCore

private final class StatsTestClock: @unchecked Sendable {
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

    func advance(_ seconds: Double) {
        continuous += seconds
        uptime += seconds
        wall = wall.addingTimeInterval(seconds)
    }
}

@MainActor
final class StatsRedesignTests: XCTestCase {
    private var tempDir: URL!
    private var cal: Calendar!

    override func setUpWithError() throws {
        try super.setUpWithError()
        Settings.dryRun = false
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pausa-stats-redesign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        cal = c
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    func testFocusStretchesRhythmScoreAndAppMerge() {
        let day = cal.date(from: DateComponents(year: 2026, month: 11, day: 16))!
        // Single 90-minute work span with one completed break at +20m and one skipped break at +40m -> stretches [20m, 70m].
        let span = WorkSpan(start: day.addingTimeInterval(9 * 3600), end: day.addingTimeInterval(10.5 * 3600))
        let breaks = [
            BreakRecord(start: day.addingTimeInterval(9 * 3600 + 20 * 60), kind: .short, planned: 20, result: .completed),
            BreakRecord(start: day.addingTimeInterval(9 * 3600 + 40 * 60), kind: .short, planned: 20, result: .skipped,
                        appBundleID: "com.microsoft.VSCode", appName: "Visual Studio Code"),
        ]
        let apps = [
            AppUsageRecord(day: day, bundleID: "com.microsoft.VSCode", appName: "Visual Studio Code", seconds: 3600),
            AppUsageRecord(day: day, bundleID: "com.google.Chrome", appName: "Google Chrome", seconds: 1800),
        ]

        let stats = Stats.days(breaks, work: [span], appUsage: apps, endingAt: day.addingTimeInterval(12 * 3600), count: 7, calendar: cal)
        XCTAssertEqual(stats.count, 7)
        let today = stats[6]
        XCTAssertEqual(today.stretches.count, 2)
        XCTAssertEqual(today.stretches[0], 20 * 60, accuracy: 0.5)
        XCTAssertEqual(today.stretches[1], 70 * 60, accuracy: 0.5)
        XCTAssertEqual(today.longestStretch, 70 * 60, accuracy: 0.5)
        XCTAssertLessThan(today.rhythmScore, 80)
        XCTAssertGreaterThanOrEqual(today.rhythmScore, 20)

        XCTAssertEqual(today.apps.count, 2)
        XCTAssertEqual(today.apps[0].bundleID, "com.microsoft.VSCode")
        XCTAssertEqual(today.apps[0].skipped, 1)
        XCTAssertEqual(today.apps[1].bundleID, "com.google.Chrome")
        XCTAssertEqual(today.apps[1].skipped, 0)
    }

    func testAdaptiveTrendScaleCeilings() {
        XCTAssertEqual(StatsTrendScale.ceilingHours(longest: 0), 2)
        XCTAssertEqual(StatsTrendScale.ceilingHours(longest: 90 * 60), 2)
        XCTAssertEqual(StatsTrendScale.ceilingHours(longest: 282 * 60), 5)
        XCTAssertEqual(StatsTrendScale.ceilingHours(longest: 318 * 60), 6)
        XCTAssertEqual(StatsTrendScale.ceilingHours(longest: 13 * 3600), 16)
        XCTAssertEqual(StatsTrendScale.ceilingHours(longest: 25 * 3600), 24)
    }

    func testBreakLogPersistsAndPrunesAppUsageAndSkipAttribution() throws {
        let logURL = tempDir.appendingPathComponent("breaks.jsonl")
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 15))!
        let expiredDay = cal.date(byAdding: .day, value: -35, to: now)!

        do {
            let log = BreakLog(url: logURL, now: now, calendar: cal, ignoreDryRun: true)
            log.recordAppUsage(bundleID: "com.old.App", appName: "OldApp", seconds: 600, at: expiredDay)
            log.recordAppUsage(bundleID: "com.apple.Safari", appName: "Safari", seconds: 900, at: now)
            log.recordAppUsage(bundleID: "com.apple.Safari", appName: "Safari", seconds: 300, at: now)
            log.append(BreakRecord(start: now, kind: .short, planned: 20, result: .skipped,
                                   appBundleID: "com.apple.Safari", appName: "Safari"))
            log.flushAppUsage(now: now)
        }

        let reloaded = BreakLog(url: logURL, now: now, calendar: cal, ignoreDryRun: true)
        let usage = reloaded.appUsage(now: now)
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage[0].bundleID, "com.apple.Safari")
        XCTAssertEqual(usage[0].seconds, 1200, accuracy: 0.1)

        let breaks = reloaded.all(now: now)
        XCTAssertEqual(breaks.count, 1)
        XCTAssertEqual(breaks[0].appBundleID, "com.apple.Safari")
        XCTAssertEqual(breaks[0].appName, "Safari")

        reloaded.clear()
        XCTAssertTrue(reloaded.appUsage(now: now).isEmpty)
        XCTAssertTrue(reloaded.all(now: now).isEmpty)
    }

    func testAppControllerTracksActiveFrontmostAppAndAttributesSkippedBreak() {
        let isolated = PausaDefaults.makeIsolated()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }

        let clock = StatsTestClock()
        let settings = Settings(defaults: isolated.defaults)
        let log = BreakLog(url: tempDir.appendingPathComponent("breaks.jsonl"), now: clock.wall, calendar: cal, ignoreDryRun: true)
        let app = AppController(
            settings: settings,
            detector: PauseDetector(defaults: isolated.defaults, clock: clock.pausaClock),
            log: log,
            clock: clock.pausaClock,
            defaults: isolated.defaults,
            inputIdle: { 1 },
            showUI: false
        )
        app.frontmostAppProvider = { ("com.microsoft.VSCode", "Visual Studio Code") }

        // Active work for 120s accumulates ~120s for VS Code.
        for _ in 0...120 {
            app.tick()
            clock.advance(1)
        }
        // Auto-paused meeting does NOT inflate active app usage.
        app.simulateReasons([.meeting])
        for _ in 0..<60 {
            app.tick()
            clock.advance(1)
        }
        app.simulateReasons([])

        let usage = log.appUsage(now: clock.wall)
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage[0].bundleID, "com.microsoft.VSCode")
        XCTAssertEqual(usage[0].seconds, 120, accuracy: 3)

        // Start a break and skip it -> BreakRecord carries VS Code attribution.
        app.breakNow(.short)
        app.finish(.skipped)
        let breaks = log.all(now: clock.wall)
        XCTAssertEqual(breaks.count, 1)
        XCTAssertEqual(breaks[0].result, .skipped)
        XCTAssertEqual(breaks[0].appBundleID, "com.microsoft.VSCode")
        XCTAssertEqual(breaks[0].appName, "Visual Studio Code")
    }

    func testAppIconResolverReadsSystemAppWithoutPermissionsAndFallsBackToMonogram() {
        // Finder is present on every macOS system and resolves via NSWorkspace without permissions.
        XCTAssertNotNil(AppIconResolver.icon(for: "com.apple.finder"))
        XCTAssertNil(AppIconResolver.icon(for: "dev.pausa.nonexistent.bundle"))
        XCTAssertEqual(AppIconResolver.monogram(for: "Visual Studio Code"), "VS")
        XCTAssertEqual(AppIconResolver.monogram(for: "Cursor"), "Cu")
        XCTAssertEqual(AppIconResolver.monogram(for: "微信"), "微")
    }

    func testStatsModelRangeClampsHistoricalSelectionWhenReturningToWeek() {
        let m = StatsModel()
        m.frozen = true
        m.calendar = cal
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 15))!
        m.now = { now }
        let oldWork = WorkSpan(start: cal.date(byAdding: .day, value: -15, to: now)!,
                               end: cal.date(byAdding: .day, value: -15, to: now)!.addingTimeInterval(3600))
        m.load = { ([], [oldWork], nil, []) }
        m.reload()

        m.range = .month
        XCTAssertEqual(m.days.count, 30)
        m.select(14)   // 15 days ago (outside the 7-day window)
        XCTAssertFalse(m.isToday)

        m.range = .week
        XCTAssertEqual(m.days.count, 7)
        XCTAssertTrue(m.isToday)
    }

    func testThreeClockIdleRollbackScreenEngagementAndSkipRedemption() {
        let isolated = PausaDefaults.makeIsolated()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }

        let clock = StatsTestClock()
        var currentIdle: Double = 0
        let settings = Settings(defaults: isolated.defaults)
        let detector = PauseDetector(defaults: isolated.defaults, clock: clock.pausaClock)
        let log = BreakLog(url: tempDir.appendingPathComponent("breaks.jsonl"), now: clock.wall, calendar: cal, ignoreDryRun: true)
        let app = AppController(
            settings: settings,
            detector: detector,
            log: log,
            clock: clock.pausaClock,
            defaults: isolated.defaults,
            inputIdle: { currentIdle },
            showUI: false
        )
        app.frontmostAppProvider = { ("com.apple.Safari", "Safari") }

        // 1. Active work for 10m (600s), then 5m (300s) unengaged zero input -> all 3 clocks roll back to 600s!
        for _ in 0..<600 {
            currentIdle = 0
            app.tick()
            clock.advance(1)
        }
        for step in 1...300 {
            currentIdle = Double(step)
            app.tick()
            clock.advance(1)
        }
        XCTAssertTrue(app.scheduler.isAway)
        XCTAssertEqual(app.scheduler.sinceLastLongBreak, 600, accuracy: 3)
        let snapAfterIdle = log.snapshot(now: clock.wall)
        XCTAssertEqual(snapAfterIdle.work.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }, 600, accuracy: 3)
        XCTAssertEqual(log.appUsage(now: clock.wall).first?.seconds ?? 0, 600, accuracy: 3)

        // Return to desk and verify `screenEngagedOverride = true` prevents idle freeze even with pauseForBrowserVideo OFF.
        currentIdle = 0
        app.tick()
        clock.advance(1)
        settings.pauseForBrowserVideo = false
        detector.screenEngagedOverride = true
        for step in 1...360 {
            currentIdle = Double(step)
            app.tick()
            clock.advance(1)
        }
        XCTAssertFalse(app.scheduler.isAway)
        detector.screenEngagedOverride = nil

        // 2. Skip a short break, then take a manual short break within 5 minutes -> skip is redeemed!
        currentIdle = 1
        app.breakNow(.short)
        app.finish(.skipped)
        XCTAssertEqual(Stats.days(log.all(now: clock.wall), endingAt: clock.wall, count: 1, calendar: cal)[0].skipped, 1)

        clock.advance(60)
        app.breakNow(.short)
        app.finish(.completed)
        let dayAfterRedeem = Stats.days(log.all(now: clock.wall), endingAt: clock.wall, count: 1, calendar: cal)[0]
        XCTAssertEqual(dayAfterRedeem.skipped, 0)
        XCTAssertEqual(dayAfterRedeem.taken, 1)
    }

    func testUrgentPauseExpiresAfterThirtyMinutesAndHoursGateClearsManualPause() throws {
        let isolated = PausaDefaults.makeIsolated()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }

        let clock = StatsTestClock()
        clock.wall = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 10, minute: 0))!
        let settings = Settings(defaults: isolated.defaults)
        settings.hardLineMinutes = 60
        let log = BreakLog(url: tempDir.appendingPathComponent("breaks.jsonl"), now: clock.wall, calendar: cal, ignoreDryRun: true)
        let app = AppController(
            settings: settings,
            detector: PauseDetector(defaults: isolated.defaults, clock: clock.pausaClock),
            log: log,
            clock: clock.pausaClock,
            defaults: isolated.defaults,
            inputIdle: { 1 },
            showUI: false
        )

        // Reach 60m hard line via meeting, end meeting -> forced long break starts, trigger urgentPause.
        app.simulateReasons([.meeting])
        for _ in 0..<3610 {
            clock.advance(1)
            app.tick()
        }
        app.simulateReasons([])
        XCTAssertTrue(app.isOnBreak)
        app.urgentPause()
        XCTAssertTrue(app.manualPaused)

        // 29 minutes later: still manually paused. At 30m + 1s: auto-recovers and enforces the owed long break!
        clock.advance(29 * 60)
        app.tick()
        XCTAssertTrue(app.manualPaused)
        clock.advance(65)
        app.tick()
        XCTAssertFalse(app.manualPaused)
        XCTAssertTrue(app.isOnBreak)
        app.finish(.completed)

        // Manual pause outside active hours clears automatically when the morning window opens.
        settings.schedule = PausaSchedule(
            enabled: true,
            rules: [PausaWindow(start: ClockTime(9, 0), end: ClockTime(18, 0), weekdays: Set(1...7))]
        )
        clock.wall = cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 8, minute: 50))!
        app.tick()
        app.pause()
        XCTAssertTrue(app.manualPaused)

        clock.advance(15 * 60)   // 09:05 -> window opens
        app.tick()
        XCTAssertFalse(app.manualPaused)
    }
}
