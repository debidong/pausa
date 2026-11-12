import AppKit
import XCTest
@testable import Pausa
@testable import PausaCore

private final class StepClock: @unchecked Sendable {
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

    func advance(_ seconds: Double) {
        continuous += seconds
        uptime += seconds
        wall = wall.addingTimeInterval(seconds)
    }
}

@MainActor
final class MenuBarAndControllerExtendedTests: XCTestCase {
    private var tempDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        Settings.dryRun = true
        UpdateModel.shared.phase = .idle
        UpdateModel.shared.canInstall = true
        AppLanguage.override = nil
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pausa-ext-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let isolated = PausaDefaults.makeIsolated()
        defaults = isolated.defaults
        suiteName = isolated.suiteName
    }

    override func tearDownWithError() throws {
        UpdateModel.shared.phase = .idle
        UpdateModel.shared.canInstall = true
        AppLanguage.override = nil
        Settings.dryRun = false
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    private func makeApp(clock: StepClock, settings: Settings? = nil, log: BreakLog? = nil) -> AppController {
        let s = settings ?? Settings(defaults: defaults)
        let l = log ?? BreakLog(url: tempDir.appendingPathComponent("breaks.jsonl"), now: clock.wall, ignoreDryRun: true)
        return AppController(
            settings: s,
            detector: PauseDetector(defaults: defaults, clock: clock.pausaClock),
            log: l,
            clock: clock.pausaClock,
            defaults: defaults,
            inputIdle: { 1 },
            showUI: false
        )
    }

    // MARK: - MenuBarController Geometry, Formatting & PopoverState Projection

    func testMenuBarNotchGeometryIconsAndWelcomeDuration() {
        let left = NSRect(x: 0, y: 1080, width: 620, height: 37)
        let right = NSRect(x: 892, y: 1080, width: 620, height: 37)

        // Visible in right menu bar area -> not under notch.
        XCTAssertFalse(MenuBarController.underNotch(NSRect(x: 950, y: 1080, width: 28, height: 24), leftArea: left, rightArea: right))
        // Visible in left menu bar area -> not under notch.
        XCTAssertFalse(MenuBarController.underNotch(NSRect(x: 500, y: 1080, width: 28, height: 24), leftArea: left, rightArea: right))
        // Straddling right edge of notch or fully behind notch -> under notch.
        XCTAssertTrue(MenuBarController.underNotch(NSRect(x: 880, y: 1080, width: 28, height: 24), leftArea: left, rightArea: right))
        XCTAssertTrue(MenuBarController.underNotch(NSRect(x: 720, y: 1080, width: 28, height: 24), leftArea: left, rightArea: right))
        // Non-notch external display (nil auxiliary areas) -> never under notch.
        XCTAssertFalse(MenuBarController.underNotch(NSRect(x: 720, y: 1080, width: 28, height: 24), leftArea: nil, rightArea: nil))

        // Icon rendering: normal/paused icons are template images; warning icon is tinted (non-template).
        let normalIcon = MenuBarController.icon(fraction: 0.5, paused: false, warning: false)
        let pausedIcon = MenuBarController.icon(fraction: 0.5, paused: true, warning: false)
        let warningIcon = MenuBarController.icon(fraction: 0.8, paused: false, warning: true)
        XCTAssertTrue(normalIcon.isTemplate)
        XCTAssertTrue(pausedIcon.isTemplate)
        XCTAssertFalse(warningIcon.isTemplate)

        // Welcome duration uses localized DateComponentsFormatter for both sub-hour and multi-hour values.
        XCTAssertFalse(MenuBarController.welcomeDuration(20 * 60).isEmpty)
        XCTAssertFalse(MenuBarController.welcomeDuration(90 * 60).isEmpty)
    }

    func testMenuBarPopoverStateAcrossWorkingPausedBreakHardLineAndUpdate() {
        let clock = StepClock()
        let app = makeApp(clock: clock)
        app.tick()

        // 1. Initial working state (short break next: shortDeferBudget is 10m, so +5m is shown/enabled and +15m is hidden).
        UpdateModel.shared.phase = .readyToInstall(version: "0.7.0")
        let working = MenuBarController.state(of: app)
        XCTAssertEqual(working.kind, .short)
        XCTAssertFalse(working.held)
        XCTAssertTrue(working.canBreak)
        XCTAssertTrue(working.can5)
        XCTAssertFalse(working.can15)
        XCTAssertFalse(working.show15)
        XCTAssertFalse(working.hardLine)
        XCTAssertFalse(working.manualPaused)
        XCTAssertFalse(working.autoPaused)
        XCTAssertEqual(working.update, "0.7.0")
        XCTAssertTrue(working.canInstall)
        XCTAssertTrue(UpdateModel.shared.canInstall)

        // Advance two short breaks so the upcoming break is `.long` (longDeferBudget is 30m -> both +5m and +15m enabled).
        for _ in 0..<2 {
            app.breakNow(.short)
            app.pause()
            app.resume()
        }
        let workingLong = MenuBarController.state(of: app)
        XCTAssertEqual(workingLong.kind, .long)
        XCTAssertTrue(workingLong.can5)
        XCTAssertTrue(workingLong.can15)
        XCTAssertTrue(workingLong.show15)

        // 2. Active break blocks relaunch / install and disables `canBreak` + postpone buttons.
        app.breakNow(.short)
        let onBreak = MenuBarController.state(of: app)
        XCTAssertTrue(onBreak.held)
        XCTAssertFalse(onBreak.canBreak)
        XCTAssertFalse(onBreak.can5)
        XCTAssertFalse(onBreak.canInstall)
        XCTAssertFalse(UpdateModel.shared.canInstall)

        // End break via manual pause -> manualPaused is true, autoPaused is false, relaunch unblocked.
        app.pause()
        let manual = MenuBarController.state(of: app)
        XCTAssertTrue(manual.held)
        XCTAssertTrue(manual.manualPaused)
        XCTAssertFalse(manual.autoPaused)
        XCTAssertTrue(manual.canInstall)
        app.resume()

        // 3. Auto-paused by meeting -> autoPaused is true, held is true.
        app.simulateReasons([.meeting])
        let autoPaused = MenuBarController.state(of: app)
        XCTAssertTrue(autoPaused.held)
        XCTAssertTrue(autoPaused.autoPaused)
        XCTAssertFalse(autoPaused.manualPaused)
        app.simulateReasons([])

        // 4. Advance past 90-minute hard line (skipping breaks along the way) -> hardLine == true, can5 == false.
        for _ in 0..<5_405 {
            clock.advance(1)
            app.tick()
            if app.isOnBreak {
                // Settle any short/long break by skipping via scheduler command path.
                app.pause()
                app.resume()
            }
        }
        // Exhaust remaining postpone budget so `can5` is false at the hard line.
        while app.scheduler.canPostpone(by: AppController.postponeShort) {
            app.postpone(by: AppController.postponeShort)
        }
        let hard = MenuBarController.state(of: app)
        XCTAssertTrue(app.scheduler.atHardLine)
        XCTAssertFalse(hard.can5)
        XCTAssertTrue(hard.hardLine)
    }

    // MARK: - AppController Snooze, Schedule Window, AutoPauseStatus & ClearStats

    func testLongBreakSnoozeFiveAndFifteenMinutes() {
        let clock = StepClock()
        let app = makeApp(clock: clock)
        app.tick()

        // Complete/skip 2 short breaks so the 3rd break in the cycle is `.long`.
        for _ in 0..<2 {
            app.breakNow(.short)
            app.pause()
            app.resume()
        }
        XCTAssertEqual(app.scheduler.next.kind, .long)

        // Start the long break and snooze 5 minutes -> next remaining is snoozeLength (300s), postpone budget untouched.
        app.breakNow(.long)
        XCTAssertTrue(app.isOnBreak)
        let longBudget = app.settings.config.longDeferBudget
        app.snooze(minutes: 5)
        XCTAssertFalse(app.isOnBreak)
        XCTAssertEqual(app.scheduler.next.kind, .long)
        XCTAssertEqual(app.scheduler.next.remaining, 300, accuracy: 1)
        XCTAssertEqual(app.scheduler.deferralLeft, longBudget, accuracy: 0.5)

        // Trigger the snoozed long break again and snooze 15 minutes -> 5m snooze + 10m (600s) from postpone budget.
        app.breakNow(.long)
        app.snooze(minutes: 15)
        XCTAssertFalse(app.isOnBreak)
        XCTAssertEqual(app.scheduler.next.kind, .long)
        XCTAssertEqual(app.scheduler.next.remaining, 900, accuracy: 1)
        XCTAssertEqual(app.scheduler.deferralLeft, longBudget - 600, accuracy: 0.5)
    }

    func testActiveHoursTransitionStartsFreshAndFormatsWhenText() throws {
        var cal = Calendar.autoupdatingCurrent
        cal.locale = Locale(identifier: "zh-Hans")
        let clock = StepClock()
        // Set wall clock to 08:30 local time today.
        let morning830 = try XCTUnwrap(cal.date(bySettingHour: 8, minute: 30, second: 0, of: Date()))
        clock.wall = morning830

        let settings = Settings(defaults: defaults)
        settings.schedule = PausaSchedule(
            enabled: true,
            rules: [PausaWindow(start: ClockTime(9, 0), end: ClockTime(18, 0), weekdays: Set(1...7))]
        )
        let app = makeApp(clock: clock, settings: settings)

        // At 08:30: outside active hours, nextWindowStart is 09:00 today, scheduler pauses with .outsideHours.
        XCTAssertTrue(app.outsideHours)
        let nextStart = try XCTUnwrap(app.nextWindowStart)
        XCTAssertEqual(cal.component(.hour, from: nextStart), 9)
        XCTAssertEqual(cal.component(.minute, from: nextStart), 0)
        app.tick()
        XCTAssertEqual(app.scheduler.phase, .paused(.outsideHours))
        XCTAssertFalse(app.statusLine.isEmpty)

        // Advance 31 minutes to 09:01 -> HoursGate detects window opening, calls startFresh, enters .working.
        clock.advance(31 * 60)
        XCTAssertFalse(app.outsideHours)
        XCTAssertNil(app.nextWindowStart)
        app.tick()
        XCTAssertEqual(app.scheduler.phase, .working)
        XCTAssertEqual(app.scheduler.next.remaining, settings.config.breakEvery, accuracy: 2)

        // Verify whenText formatting for today, tomorrow, and 3 days later.
        AppLanguage.override = .zhHans
        let todayText = AppController.whenText(nextStart, cal: cal)
        let tomorrowDate = try XCTUnwrap(cal.date(byAdding: .day, value: 1, to: nextStart))
        let tomorrowText = AppController.whenText(tomorrowDate, cal: cal)
        let laterDate = try XCTUnwrap(cal.date(byAdding: .day, value: 3, to: nextStart))
        let laterText = AppController.whenText(laterDate, cal: cal)

        XCTAssertTrue(todayText.contains("9:00"))
        XCTAssertTrue(tomorrowText.contains("9:00"))
        XCTAssertNotEqual(todayText, tomorrowText)
        XCTAssertTrue(laterText.contains("9:00"))
        XCTAssertNotEqual(tomorrowText, laterText)
    }

    func testAutoPauseStatusVariantsAndClearStatsResetsOpenWorkSpan() {
        let clock = StepClock()
        let log = BreakLog(url: tempDir.appendingPathComponent("breaks.jsonl"), now: clock.wall, ignoreDryRun: true)
        let app = makeApp(clock: clock, log: log)

        // 1. Hold pause statuses (browserVideo, screenSharing, recording) and their localized title/detail.
        app.simulateReasons([.browserVideo(appName: "Safari")])
        if case .browserVideo(let name)? = app.autoPauseStatus {
            XCTAssertEqual(name, "Safari")
            XCTAssertFalse(app.autoPauseStatus!.title.isEmpty)
            XCTAssertNotNil(app.autoPauseStatus!.detail)
        } else {
            XCTFail("Expected .browserVideo status, got \(String(describing: app.autoPauseStatus))")
        }

        app.simulateReasons([.screenSharing(appName: "Zoom")])
        if case .screenSharing(let name)? = app.autoPauseStatus {
            XCTAssertEqual(name, "Zoom")
            XCTAssertNotNil(app.autoPauseStatus!.detail)
        } else {
            XCTFail("Expected .screenSharing status")
        }

        app.simulateReasons([.recording(appName: "OBS")])
        if case .screenRecording(let name)? = app.autoPauseStatus {
            XCTAssertEqual(name, "OBS")
            XCTAssertNotNil(app.autoPauseStatus!.detail)
        } else {
            XCTFail("Expected .screenRecording status")
        }
        app.simulateReasons([])

        // 2. Soft deferral statuses when a short break comes due.
        app.detector.extraDeferrals = [.typing]
        for _ in 0..<Int(app.settings.config.breakEvery) + 2 {
            clock.advance(1)
            app.tick()
        }
        if case .typing(let left)? = app.autoPauseStatus {
            XCTAssertGreaterThan(left, 0)
            XCTAssertNotNil(app.autoPauseStatus!.detail)
        } else {
            XCTFail("Expected .typing deferral status, got \(String(describing: app.autoPauseStatus))")
        }

        app.detector.extraDeferrals = [.focusMode(shortOnly: true)]
        clock.advance(1)
        app.tick()
        if case .focus(_, let scope)? = app.autoPauseStatus {
            XCTAssertEqual(scope, app.settings.focusModeScope)
            XCTAssertNil(app.autoPauseStatus!.detail)
        } else {
            XCTFail("Expected .focus deferral status, got \(String(describing: app.autoPauseStatus))")
        }
        app.detector.extraDeferrals = []

        // 3. `clearStats()` closes any open work span and wipes logged history cleanly.
        var statsChangedCount = 0
        app.onStatsChanged = { statsChangedCount += 1 }
        app.breakNow(.short)
        app.pause()
        app.resume()
        clock.advance(10)
        app.tick()
        XCTAssertNotNil(app.openWorkSpan)

        app.clearStats()
        XCTAssertNil(app.openWorkSpan)
        XCTAssertGreaterThanOrEqual(statsChangedCount, 2)
        let snap = log.snapshot(now: clock.wall)
        XCTAssertTrue(snap.breaks.isEmpty)
        XCTAssertTrue(snap.work.isEmpty)
    }

    // MARK: - Updater Delegate Relaunch Postponement

    func testUpdaterShouldPostponeRelaunchHoldsWhileBlockedAndProceedsOnClearance() {
        let updater = Updater()
        var blocked = true
        var handlerInvoked = 0
        updater.canInstallNow = { !blocked }

        // While overlay is blocking, delegate postpones relaunch and moves into `.readyToInstall`.
        let postponed = updater.shouldPostponeRelaunch(version: "0.6.4") {
            handlerInvoked += 1
        }
        XCTAssertTrue(postponed)
        XCTAssertEqual(updater.phase, .readyToInstall(version: "0.6.4"))
        XCTAssertEqual(handlerInvoked, 0)

        // Calling retryHeldInstall while still blocked is a no-op.
        updater.retryHeldInstall()
        XCTAssertEqual(handlerInvoked, 0)

        // Once overlay clears, retryHeldInstall transitions to `.installing` and invokes Sparkle's block once.
        blocked = false
        updater.retryHeldInstall()
        XCTAssertEqual(updater.phase, .installing(version: "0.6.4"))
        XCTAssertEqual(handlerInvoked, 1)

        // Direct unblocked delegate call proceeds immediately without postponing.
        let updater2 = Updater()
        updater2.canInstallNow = { true }
        XCTAssertFalse(updater2.shouldPostponeRelaunch(version: "0.6.5") {})
        XCTAssertEqual(updater2.phase, .installing(version: ""))
    }

    func testCleanBackdropViewConfiguresLightBlurAndHidesCoreUIMudLayers() {
        _ = NSApplication.shared
        let window = NSPanel(
            contentRect: NSRect(x: -5000, y: -5000, width: 200, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0
        let container = BreakOverlayController.makeBlurView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 120),
            tint: BreakOverlayController.shortDim,
            blurRadius: BreakOverlayController.shortBlurRadius
        )
        window.contentView = container
        window.orderFrontRegardless()
        container.layoutSubtreeIfNeeded()
        container.displayIfNeeded()
        CATransaction.flush()
        defer { window.orderOut(nil) }

        guard let backdropView = container.subviews.compactMap({ $0 as? CleanBackdropView }).first else {
            return XCTFail("Expected CleanBackdropView inside makeBlurView container")
        }
        XCTAssertEqual(container.subviews.count, 2)
        XCTAssertEqual(backdropView.blurRadius, BreakOverlayController.shortBlurRadius)

        backdropView.reconfigureBackdrop(reduceTransparency: false)
        if let root = backdropView.layer?.sublayers?.first(where: {
            ($0.sublayers ?? []).contains(where: { String(describing: type(of: $0)) == "CABackdropLayer" })
        }), let bd = root.sublayers?.first(where: { String(describing: type(of: $0)) == "CABackdropLayer" }) {
            let scale = (bd.value(forKey: "scale") as? NSNumber)?.doubleValue
            XCTAssertEqual(scale ?? 0, 0.5, accuracy: 0.01)
            let radius = (bd.value(forKeyPath: "filters.gaussianBlur.inputRadius") as? NSNumber)?.doubleValue
            if let radius {
                XCTAssertEqual(radius, BreakOverlayController.shortBlurRadius, accuracy: 0.01)
            }
            for sibling in root.sublayers ?? [] where sibling !== bd {
                XCTAssertTrue(sibling.isHidden, "Expected CoreUI fill/tone/chameleon layer \(sibling.name ?? "") to be hidden")
            }

            // Under Reduce Transparency, fallback fill layers must remain visible.
            backdropView.reconfigureBackdrop(reduceTransparency: true)
            for sibling in root.sublayers ?? [] where sibling !== bd {
                XCTAssertFalse(sibling.isHidden)
            }
        }
    }

    func testBundledChimeFilesLoadAsStereoAcousticSounds() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let soundsDir = repoRoot.appendingPathComponent("App/sounds", isDirectory: true)
        for chime in Chime.allCases {
            let url = soundsDir.appendingPathComponent("\(chime.name).caf")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing \(url.path)")
            let sound = try XCTUnwrap(NSSound(contentsOf: url, byReference: false), "Failed to load \(chime.name).caf")
            XCTAssertGreaterThan(sound.duration, 2.0, "\(chime.name).caf duration too short")
            XCTAssertLessThan(sound.duration, 5.0, "\(chime.name).caf duration unexpectedly long")
        }
    }

    func testUpdaterWillInstallOnQuitAutoRestartsImmediatelyOrDefersUntilOverlayClears() {
        // Unblocked: auto-restarts right away without waiting for manual click.
        let immediate = Updater()
        var immediateRuns = 0
        immediate.canInstallNow = { true }
        let handled = immediate.handleWillInstallOnQuit(version: "0.6.7") {
            immediateRuns += 1
        }
        XCTAssertTrue(handled)
        XCTAssertEqual(immediateRuns, 1)
        XCTAssertEqual(immediate.phase, .installing(version: "0.6.7"))

        // Blocked by break/preview: holds until overlay clears, then auto-restarts once.
        let deferred = Updater()
        var blocked = true
        var deferredRuns = 0
        deferred.canInstallNow = { !blocked }
        let held = deferred.handleWillInstallOnQuit(version: "0.6.7") {
            deferredRuns += 1
        }
        XCTAssertTrue(held)
        XCTAssertEqual(deferredRuns, 0)
        XCTAssertEqual(deferred.phase, .readyToInstall(version: "0.6.7"))

        blocked = false
        deferred.retryHeldInstall()
        XCTAssertEqual(deferredRuns, 1)
        XCTAssertEqual(deferred.phase, .installing(version: "0.6.7"))
    }

    func testUpdaterShouldRefreshOnWakePolicy() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(Updater.shouldRefreshOnWake(lastCheck: nil, interval: 3600, phase: .idle, now: now))
        XCTAssertFalse(Updater.shouldRefreshOnWake(lastCheck: now.addingTimeInterval(-1200), interval: 3600, phase: .upToDate, now: now))
        XCTAssertTrue(Updater.shouldRefreshOnWake(lastCheck: now.addingTimeInterval(-3601), interval: 3600, phase: .upToDate, now: now))
        XCTAssertTrue(Updater.shouldRefreshOnWake(lastCheck: now.addingTimeInterval(-60), interval: 3600, phase: .failed(message: "offline"), now: now))
    }
}
