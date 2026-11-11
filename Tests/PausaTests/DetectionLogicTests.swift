import CoreGraphics
import Darwin
import XCTest
@testable import Pausa
@testable import PausaCore

final class DetectionLogicTests: XCTestCase {

    // MARK: - ProcessLineage

    func testProcessLineageOuterAppBundleAndLiveProcessQueries() {
        // Nested Chromium helper .app resolves to the outermost browser .app bundle.
        let chromeHelper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)"
        XCTAssertEqual(ProcessLineage.outerAppBundle(chromeHelper), "/Applications/Google Chrome.app")

        // Plain .app bundle paths with or without trailing slash.
        XCTAssertEqual(ProcessLineage.outerAppBundle("/Applications/Safari.app"), "/Applications/Safari.app")
        XCTAssertEqual(ProcessLineage.outerAppBundle("/Applications/Safari.app/"), "/Applications/Safari.app")

        // Non-.app paths (including directories whose name starts with ".app" like ".application") must return nil.
        XCTAssertNil(ProcessLineage.outerAppBundle("/Users/alice/foo.application/bin/helper"))
        XCTAssertNil(ProcessLineage.outerAppBundle("/usr/libexec/replayd"))

        // Live current process queries work without elevated permissions.
        let selfPID = getpid()
        let selfPath = ProcessLineage.path(of: selfPID)
        XCTAssertNotNil(selfPath)
        XCTAssertFalse(selfPath?.isEmpty ?? true)

        let chain = ProcessLineage.lineage(of: selfPID)
        XCTAssertEqual(chain.first, selfPID)
        if getppid() > 1 {
            XCTAssertEqual(ProcessLineage.parent(of: selfPID), getppid())
            XCTAssertTrue(chain.contains(getppid()))
        }

        // Invalid PIDs fail gracefully.
        XCTAssertNil(ProcessLineage.path(of: -1))
        XCTAssertNil(ProcessLineage.parent(of: -1))
    }

    // MARK: - PausaCore VideoSignal & StatusPick

    func testVideoSignalAndStatusPickRules() {
        let validChromium = VideoSignal.Holder(pid: 101, type: "NoDisplaySleepAssertion", name: "Video Wake Lock")
        let validSafari = VideoSignal.Holder(pid: 102, type: "PreventUserIdleDisplaySleep", name: "com.apple.WebCore: HTMLMediaElement playback")
        let wrongName = VideoSignal.Holder(pid: 101, type: "NoDisplaySleepAssertion", name: "Capturing")
        let wrongType = VideoSignal.Holder(pid: 101, type: "PreventUserIdleSystemSleep", name: "Video Wake Lock")

        XCTAssertTrue(VideoSignal.isPlayback(type: validChromium.type, name: validChromium.name))
        XCTAssertTrue(VideoSignal.isPlayback(type: validSafari.type, name: validSafari.name))
        XCTAssertFalse(VideoSignal.isPlayback(type: wrongName.type, name: wrongName.name))
        XCTAssertFalse(VideoSignal.isPlayback(type: wrongType.type, name: wrongType.name))
        XCTAssertFalse(VideoSignal.isPlayback(type: nil, name: "Video Wake Lock"))

        let holders = [wrongName, wrongType, validChromium]
        XCTAssertTrue(VideoSignal.frontIsPlaying(holders) { $0 == 101 })
        XCTAssertFalse(VideoSignal.frontIsPlaying(holders) { $0 == 999 })

        // StatusPick prioritizes source ?? autoStatus ?? reason.
        XCTAssertEqual(StatusPick.line(source: "S", autoStatus: "A", reason: "R"), "S")
        XCTAssertEqual(StatusPick.line(source: nil, autoStatus: "A", reason: "R"), "A")
        XCTAssertEqual(StatusPick.line(source: nil, autoStatus: nil, reason: "R"), "R")
        XCTAssertNil(StatusPick.line(source: nil, autoStatus: nil, reason: nil))
    }

    // MARK: - FullscreenMonitor

    private func cgWindow(pid: pid_t, layer: Int, rect: CGRect, alpha: Double = 1.0) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: rect.dictionaryRepresentation as NSDictionary,
            kCGWindowAlpha as String: alpha,
        ]
    }

    func testFullscreenMonitorAllowlistGameCategoryAndWindowCoverage() {
        XCTAssertTrue(FullscreenMonitor.pausingBundleIDs.contains("com.colliderli.iina"))
        XCTAssertTrue(FullscreenMonitor.pausingBundleIDs.contains("com.apple.iWork.Keynote"))
        XCTAssertFalse(FullscreenMonitor.pausingBundleIDs.contains("com.google.Chrome"))
        XCTAssertFalse(FullscreenMonitor.pausingBundleIDs.contains("com.apple.dt.Xcode"))

        XCTAssertTrue(FullscreenMonitor.isGameCategory("public.app-category.games"))
        XCTAssertTrue(FullscreenMonitor.isGameCategory("public.app-category.action-games"))
        XCTAssertFalse(FullscreenMonitor.isGameCategory("public.app-category.developer-tools"))
        XCTAssertFalse(FullscreenMonitor.isGameCategory(nil))

        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let external = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let displays = [primary, external]

        // Normal fullscreen window (including 1pt inset tolerance) covers display.
        let exact = [cgWindow(pid: 500, layer: 0, rect: CGRect(x: 0, y: 0, width: 1919, height: 1079))]
        XCTAssertTrue(FullscreenMonitor.windowCoversAnyDisplay(pid: 500, windows: exact, displays: displays))

        // Fullscreen on secondary display also counts.
        let onExternal = [cgWindow(pid: 500, layer: 0, rect: external)]
        XCTAssertTrue(FullscreenMonitor.windowCoversAnyDisplay(pid: 500, windows: onExternal, displays: displays))

        // Non-matching PID, partial window, low alpha (< 0.1), negative layer, or menu-bar layer do not count.
        XCTAssertFalse(FullscreenMonitor.windowCoversAnyDisplay(pid: 501, windows: exact, displays: displays))

        let partial = [cgWindow(pid: 500, layer: 0, rect: CGRect(x: 100, y: 100, width: 1400, height: 900))]
        XCTAssertFalse(FullscreenMonitor.windowCoversAnyDisplay(pid: 500, windows: partial, displays: displays))

        let transparent = [cgWindow(pid: 500, layer: 0, rect: primary, alpha: 0.05)]
        XCTAssertFalse(FullscreenMonitor.windowCoversAnyDisplay(pid: 500, windows: transparent, displays: displays))

        let menuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
        let highLayer = [cgWindow(pid: 500, layer: menuLayer, rect: primary)]
        XCTAssertFalse(FullscreenMonitor.windowCoversAnyDisplay(pid: 500, windows: highLayer, displays: displays))

        let negativeLayer = [cgWindow(pid: 500, layer: -1, rect: primary)]
        XCTAssertFalse(FullscreenMonitor.windowCoversAnyDisplay(pid: 500, windows: negativeLayer, displays: displays))
    }

    // MARK: - ScreenShareMonitor

    func testScreenShareMonitorWindowHeuristicsAndPersistence() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var tracker = ScreenShareMonitor.Tracker()

        // 1. Recorder normal main window (layer 0) does NOT trigger recording, while floating small bar (layer > 0) DOES.
        let obsMain = [(owner: "OBS", bundleID: "com.obsproject.obs-studio", layer: 0, bounds: CGRect(x: 100, y: 100, width: 300, height: 80))]
        XCTAssertNil(ScreenShareMonitor.evaluate(windows: obsMain, screens: [screen], inMeeting: false, tracker: &tracker, now: 10))

        let obsFloating = [(owner: "OBS", bundleID: "com.obsproject.obs-studio", layer: 3, bounds: CGRect(x: 100, y: 40, width: 320, height: 64))]
        XCTAssertEqual(
            ScreenShareMonitor.evaluate(windows: obsFloating, screens: [screen], inMeeting: false, tracker: &tracker, now: 11),
            .recording("OBS")
        )

        // 2. Meeting app full-screen share border requires `inMeeting == true` and `layer > 0`.
        let zoomBorder = [(owner: "Zoom", bundleID: "us.zoom.xos", layer: 3, bounds: CGRect(x: 2, y: 2, width: 1916, height: 1076))]
        XCTAssertNil(ScreenShareMonitor.evaluate(windows: zoomBorder, screens: [screen], inMeeting: false, tracker: &tracker, now: 20))
        XCTAssertEqual(
            ScreenShareMonitor.evaluate(windows: zoomBorder, screens: [screen], inMeeting: true, tracker: &tracker, now: 21),
            .sharing("Zoom")
        )

        // Active meeting share takes priority over a concurrent recorder toolbar.
        let both = obsFloating + zoomBorder
        XCTAssertEqual(
            ScreenShareMonitor.evaluate(windows: both, screens: [screen], inMeeting: true, tracker: &tracker, now: 22),
            .sharing("Zoom")
        )

        // 3. Chromium bottom-centered floating share bar requires 3s persistence + `inMeeting == true`.
        let chromeBar = [(owner: "Chrome", bundleID: "com.google.Chrome", layer: 3, bounds: CGRect(x: 760, y: 1000, width: 400, height: 48))]
        XCTAssertNil(ScreenShareMonitor.evaluate(windows: chromeBar, screens: [screen], inMeeting: true, tracker: &tracker, now: 30.0))
        XCTAssertNil(ScreenShareMonitor.evaluate(windows: chromeBar, screens: [screen], inMeeting: true, tracker: &tracker, now: 32.9))
        XCTAssertEqual(
            ScreenShareMonitor.evaluate(windows: chromeBar, screens: [screen], inMeeting: true, tracker: &tracker, now: 33.0),
            .sharing("Chrome")
        )

        // A top-aligned floating browser popup (e.g. find/permission bubble) is NOT bottom-centered and resets the bar tracker.
        let chromeTopPopup = [(owner: "Chrome", bundleID: "com.google.Chrome", layer: 3, bounds: CGRect(x: 760, y: 80, width: 400, height: 48))]
        XCTAssertNil(ScreenShareMonitor.evaluate(windows: chromeTopPopup, screens: [screen], inMeeting: true, tracker: &tracker, now: 34.0))
        XCTAssertNil(tracker.browserBarSince)
    }

    // MARK: - PauseSource, PauseReason & PauseDetector Away Nesting

    func testPauseSourcePauseReasonAndMeetingOwnerSelection() {
        let webMeeting = PauseSource(kind: .meeting, appName: "Google Chrome", bundleID: "com.google.Chrome", website: "Google Meet")
        XCTAssertEqual(webMeeting.displayName, "Google Meet")
        XCTAssertEqual(webMeeting.core, .meeting)
        XCTAssertFalse(webMeeting.statusText.isEmpty)

        let nativeShare = PauseSource(kind: .screenSharing, appName: "Zoom", bundleID: "us.zoom.xos")
        XCTAssertEqual(nativeShare.displayName, "Zoom")
        XCTAssertEqual(nativeShare.core, .screenSharing)
        XCTAssertFalse(nativeShare.statusText.isEmpty)

        XCTAssertEqual(PauseSource(kind: .video).core, .video)
        XCTAssertEqual(PauseSource(kind: .fullscreen).core, .fullscreen)
        XCTAssertNil(PauseSource(kind: .meeting).displayName)

        let reasons: [(Pausa.PauseReason, PausaCore.PauseReason, String)] = [
            (.meeting, .meeting, "meeting"),
            (.micInUse, .micInUse, "micInUse"),
            (.fullscreen(appName: "IINA"), .fullscreen, "fullscreen(IINA)"),
            (.browserVideo(appName: "Safari"), .video, "browserVideo(Safari)"),
            (.screenSharing(appName: "Zoom"), .screenSharing, "screenSharing(Zoom)"),
            (.recording(appName: "OBS"), .screenSharing, "recording(OBS)"),
        ]
        for (r, expectedCore, expectedDesc) in reasons {
            XCTAssertEqual(r.core, expectedCore)
            XCTAssertEqual(r.description, expectedDesc)
            XCTAssertFalse(r.pausedText.isEmpty)
        }

        // Meeting owner preference: dedicated meeting app > browser > generic app.
        struct FakeApp: Equatable { let name: String; let id: String }
        let voiceMemos = FakeApp(name: "Voice Memos", id: "com.apple.VoiceMemos")
        let safari = FakeApp(name: "Safari", id: "com.apple.Safari")
        let zoom = FakeApp(name: "Zoom", id: "us.zoom.xos")

        XCTAssertEqual(MicUserMonitor.pickMeetingOwner([voiceMemos, safari, zoom], bundleID: \.id), zoom)
        XCTAssertEqual(MicUserMonitor.pickMeetingOwner([voiceMemos, safari], bundleID: \.id), safari)
        XCTAssertEqual(MicUserMonitor.pickMeetingOwner([voiceMemos], bundleID: \.id), voiceMemos)
        XCTAssertNil(MicUserMonitor.pickMeetingOwner([FakeApp](), bundleID: \.id))
    }

    func testPauseDetectorDeduplicatesNestedLockDisplaySleepAndSystemSleep() {
        let detector = PauseDetector()
        var events: [String] = []
        detector.onAway = { event in
            switch event {
            case .start(let k): events.append("start:\(k.rawValue)")
            case .end(let k): events.append("end:\(k.rawValue)")
            }
        }

        // Clearing an away signal when not away is a no-op.
        detector.setAway(.displayAsleep, false)
        XCTAssertFalse(detector.isAway)
        XCTAssertTrue(events.isEmpty)

        // Screen locks -> away starts once; nested display sleep & system sleep do NOT emit duplicate starts.
        detector.setAway(.screenLocked, true)
        detector.setAway(.screenLocked, true)
        detector.setAway(.displayAsleep, true)
        detector.setAway(.systemAsleep, true)
        XCTAssertTrue(detector.isAway)
        XCTAssertEqual(events, ["start:screenLocked"])

        // System wakes and display wakes while screen is still locked -> stays away, no end emitted yet.
        detector.setAway(.systemAsleep, false)
        detector.setAway(.displayAsleep, false)
        XCTAssertTrue(detector.isAway)
        XCTAssertEqual(events, ["start:screenLocked"])

        // Screen unlocks -> last away reason clears, emitting exactly one end event.
        detector.setAway(.screenLocked, false)
        XCTAssertFalse(detector.isAway)
        XCTAssertEqual(events, ["start:screenLocked", "end:screenLocked"])
    }
}
