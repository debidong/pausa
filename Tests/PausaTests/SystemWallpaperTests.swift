import AVFoundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Pausa
@testable import PausaCore

@MainActor
final class SystemWallpaperTests: XCTestCase {
    private var tempDir: URL!
    private var savedTheme: ThemeChoice!

    override func setUpWithError() throws {
        try super.setUpWithError()
        Settings.dryRun = true
        PausaDefaults.resetDryRunStore()
        savedTheme = Settings.shared.theme
        SystemWallpaper.probeOverride = nil
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pausa-syswall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        SystemWallpaper.probeOverride = nil
        if let savedTheme { Settings.shared.theme = savedTheme }
        Settings.dryRun = false
        PausaDefaults.resetDryRunStore()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeSolidImage(width: Int = 160, height: Int = 100, r: CGFloat, g: CGFloat, b: CGFloat) throws -> CGImage {
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func writeImages(_ images: [CGImage], type: UTType, to url: URL) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil))
        for img in images { CGImageDestinationAddImage(dest, img, nil) }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func encodeConfigPlist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
    }

    private func writeTinyMOV(to url: URL, r: UInt8, g: UInt8, b: UInt8) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 96
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: 160,
            kCVPixelBufferHeightKey as String: 96
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<3 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 160, 96, kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pb)
            let buf = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                let bpr = CVPixelBufferGetBytesPerRow(buf)
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<96 {
                    for x in 0..<160 {
                        let o = y * bpr + x * 4
                        ptr[o] = 255; ptr[o + 1] = r; ptr[o + 2] = g; ptr[o + 3] = b
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            XCTAssertTrue(adaptor.append(buf, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    // MARK: - 1. Lexical Normalization & TCC Bucket Classification

    func testLexicalNormalizationAndTCCClassificationNeverTouchFilesystem() {
        let home = "/Users/alice"
        XCTAssertEqual(SystemWallpaper.tccBucket(forPath: "/Users/alice/Desktop/wall.jpg", home: home), .desktop)
        XCTAssertEqual(SystemWallpaper.tccBucket(forPath: "~/Documents/sub/bg.heic", home: home), .documents)
        XCTAssertEqual(SystemWallpaper.tccBucket(forPath: "/Users/alice/Downloads/pic.png", home: home), .downloads)
        XCTAssertEqual(SystemWallpaper.tccBucket(forPath: "/Users/alice/Library/Mobile Documents/com~apple~CloudDocs/a.jpg", home: home), .icloud)
        XCTAssertEqual(SystemWallpaper.tccBucket(forPath: "/Volumes/ExternalSSD/Wallpapers/1.jpg", home: home), .externalVolume)

        // Lexical `..` traversal into Desktop must still be caught as `.desktop`.
        XCTAssertEqual(SystemWallpaper.tccBucket(forPath: "/Users/alice/Pictures/../Desktop/sneaky.jpg", home: home), .desktop)

        // Zero-TCC locations: Pictures (outside Photos Library), custom folders, Aerials, System Desktop Pictures.
        XCTAssertNil(SystemWallpaper.tccBucket(forPath: "/Users/alice/Pictures/wall.jpg", home: home))
        XCTAssertNil(SystemWallpaper.tccBucket(forPath: "/Users/alice/Wallpapers/wall.jpg", home: home))
        XCTAssertNil(SystemWallpaper.tccBucket(forPath: "/System/Library/Desktop Pictures/Sonoma.heic", home: home))
        XCTAssertNil(SystemWallpaper.tccBucket(
            forPath: "/Users/alice/Library/Application Support/com.apple.wallpaper/aerials/videos/B2FC91ED.mov",
            home: home
        ))

        // Photos Library & private wallpaper extension container isolation.
        XCTAssertTrue(SystemWallpaper.isPhotosOrContainerIsolated(
            path: "/Users/alice/Pictures/Photos Library.photoslibrary/originals/A/1.heic",
            home: home
        ))
        XCTAssertTrue(SystemWallpaper.isPhotosOrContainerIsolated(
            path: "/Users/alice/Library/Containers/com.apple.wallpaper.extension.image/Data/Documents/img.png",
            home: home
        ))
        XCTAssertFalse(SystemWallpaper.isPhotosOrContainerIsolated(
            path: "/Users/alice/Pictures/MyWallpapers/forest.heic",
            home: home
        ))
    }

    // MARK: - 2. Index.plist Parsing Across Aerials, Per-Display, Linked/Idle & Ventura Fallback

    func testIndexPlistResolutionCoversAerialsPerDisplayIdleFallthroughAndVentura() throws {
        let home = "/Users/alice"
        let aerialCfg = try encodeConfigPlist(["assetID": "B2FC91ED-6891-4DEB-85A1-268B2B4160B6"])

        // 1. Live Tahoe/Sequoia Linked Aerial structure (even when NSWorkspace returns DefaultDesktop.heic).
        let linkedAerialPlist: [String: Any] = [
            "AllSpacesAndDisplays": [
                "Type": "linked",
                "Linked": [
                    "Content": [
                        "Choices": [[
                            "Provider": "com.apple.wallpaper.choice.aerials",
                            "Files": [],
                            "Configuration": aerialCfg
                        ]]
                    ]
                ]
            ]
        ]
        XCTAssertEqual(
            SystemWallpaper.resolveCandidate(
                indexPlist: linkedAerialPlist,
                displayUUID: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
                desktopImagePath: "/System/Library/CoreServices/DefaultDesktop.heic",
                home: home
            ),
            .aerial(assetID: "B2FC91ED-6891-4DEB-85A1-268B2B4160B6")
        )

        // 2. Per-display override + Swift PropertyListEncoder relative/base URL dictionary.
        let perDisplayPlist: [String: Any] = [
            "Displays": [
                "aaaa-1111": [
                    "Desktop": [
                        "Content": [
                            "Choices": [[
                                "Provider": "com.apple.wallpaper.choice.image",
                                "Files": [[
                                    "relative": "My%20Photo.heic",
                                    "base": ["relative": "file:///Users/alice/Pictures/"]
                                ]]
                            ]]
                        ]
                    ]
                ]
            ],
            "AllSpacesAndDisplays": linkedAerialPlist["AllSpacesAndDisplays"]!
        ]
        XCTAssertEqual(
            SystemWallpaper.resolveCandidate(indexPlist: perDisplayPlist, displayUUID: "AAAA-1111", desktopImagePath: nil, home: home),
            .file("/Users/alice/Pictures/My Photo.heic")
        )
        XCTAssertEqual(
            SystemWallpaper.resolveCandidate(indexPlist: perDisplayPlist, displayUUID: "BBBB-2222", desktopImagePath: nil, home: home),
            .aerial(assetID: "B2FC91ED-6891-4DEB-85A1-268B2B4160B6")
        )

        // 3. Solid-color Desktop + Aerial Idle screensaver -> falls through procedural Desktop to play Aerial Idle.
        let colorDesktopAerialIdle: [String: Any] = [
            "AllSpacesAndDisplays": [
                "Desktop": ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.color"]]]],
                "Idle": ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.aerials", "Configuration": aerialCfg]]]]
            ]
        ]
        XCTAssertEqual(
            SystemWallpaper.resolveCandidate(indexPlist: colorDesktopAerialIdle, displayUUID: nil, desktopImagePath: nil, home: home),
            .aerial(assetID: "B2FC91ED-6891-4DEB-85A1-268B2B4160B6")
        )

        // 4. Photos provider & pure procedural fallback.
        let photosPlist: [String: Any] = [
            "AllSpacesAndDisplays": ["Desktop": ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.photos"]]]]]
        ]
        XCTAssertEqual(
            SystemWallpaper.resolveCandidate(indexPlist: photosPlist, displayUUID: nil, desktopImagePath: nil, home: home),
            .photosIsolated
        )
        let proceduralPlist: [String: Any] = [
            "AllSpacesAndDisplays": ["Desktop": ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.macintosh"]]]]]
        ]
        XCTAssertEqual(
            SystemWallpaper.resolveCandidate(
                indexPlist: proceduralPlist,
                displayUUID: nil,
                desktopImagePath: "/System/Library/CoreServices/DefaultDesktop.heic",
                home: home
            ),
            .procedural
        )

        // 5. macOS 13 Ventura (`indexPlist == nil`) uses desktopImageURL directly.
        XCTAssertEqual(
            SystemWallpaper.resolveCandidate(
                indexPlist: nil,
                displayUUID: nil,
                desktopImagePath: "/System/Library/CoreServices/DefaultDesktop.heic",
                home: home
            ),
            .file("/System/Library/CoreServices/DefaultDesktop.heic")
        )
    }

    // MARK: - 3. Fresh-Install Default & Zero-Popup Guarantee

    func testFreshInstallDefaultsToSystemWallpaperWhenSafeAndRandomWhenTCCRestricted() throws {
        var fileChecks = 0
        let aerialCfg = try encodeConfigPlist(["assetID": "TAHOE-1"])

        // Case A: Fresh install with Apple Aerial -> defaults to `.systemWallpaper` with 0 file checks.
        SystemWallpaper.probeOverride = .init(
            homeDirectory: "/Users/alice",
            loadIndexPlist: {
                ["AllSpacesAndDisplays": ["Linked": ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.aerials", "Configuration": aerialCfg]]]]]]
            },
            screens: { [.init(id: 1, uuid: "DISP-1", desktopImagePath: nil)] },
            aerialSearchDirs: [],
            checkReadable: { _ in fileChecks += 1; return .readable }
        )
        let (ud1, suite1) = PausaDefaults.makeIsolated()
        defer { ud1.removePersistentDomain(forName: suite1) }
        let s1 = Settings(defaults: ud1)
        XCTAssertEqual(s1.theme, .systemWallpaper)
        XCTAssertEqual(ud1.string(forKey: DefaultsKey.theme), ThemeChoice.systemWallpaper.rawValue)
        XCTAssertEqual(fileChecks, 0)

        // Case B: Fresh install with ~/Desktop custom wallpaper -> defaults to `.random` with 0 file checks!
        SystemWallpaper.probeOverride = .init(
            homeDirectory: "/Users/alice",
            loadIndexPlist: {
                ["AllSpacesAndDisplays": ["Desktop": ["Content": ["Choices": [[
                    "Provider": "com.apple.wallpaper.choice.image",
                    "Files": [["relative": "file:///Users/alice/Desktop/cat.png"]]
                ]]]]]]
            },
            screens: { [.init(id: 1, uuid: "DISP-1", desktopImagePath: "/Users/alice/Desktop/cat.png")] },
            aerialSearchDirs: [],
            checkReadable: { _ in fileChecks += 1; return .readable }
        )
        let (ud2, suite2) = PausaDefaults.makeIsolated()
        defer { ud2.removePersistentDomain(forName: suite2) }
        let s2 = Settings(defaults: ud2)
        XCTAssertEqual(s2.theme, .random)
        XCTAssertEqual(ud2.string(forKey: DefaultsKey.theme), ThemeChoice.random.rawValue)
        XCTAssertEqual(fileChecks, 0, "Must never stat/open a TCC-protected wallpaper on fresh install")

        // Case C: Upgraded user with saved theme keeps their saved theme.
        let (ud3, suite3) = PausaDefaults.makeIsolated()
        defer { ud3.removePersistentDomain(forName: suite3) }
        ud3.set(ThemeChoice.ocean.rawValue, forKey: DefaultsKey.theme)
        let s3 = Settings(defaults: ud3)
        XCTAssertEqual(s3.theme, .ocean)
    }

    // MARK: - 4. Explicit Menu Pick, TCC Authorization Flow & Folder-Switch Protection

    func testExplicitMenuPickHandlesDenialGrantAndSubsequentUnauthorizedFolderSwitch() throws {
        let fakeHome = tempDir.appendingPathComponent("home", isDirectory: true)
        let desktopDir = fakeHome.appendingPathComponent("Desktop", isDirectory: true)
        let downloadsDir = fakeHome.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: desktopDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        let desktopImg = desktopDir.appendingPathComponent("bright.png")
        let downloadsImg = downloadsDir.appendingPathComponent("other.png")
        try writeImages([makeSolidImage(r: 1, g: 1, b: 1)], type: .png, to: desktopImg)
        try writeImages([makeSolidImage(r: 0.1, g: 0.2, b: 0.3)], type: .png, to: downloadsImg)

        var currentPath = desktopImg.path
        var simulateAllowed = false
        var alerts: [SystemWallpaper.EnvironmentProbe.AlertKind] = []
        var checkedPaths: [String] = []

        SystemWallpaper.probeOverride = .init(
            homeDirectory: fakeHome.path,
            loadIndexPlist: {
                ["AllSpacesAndDisplays": ["Desktop": ["Content": ["Choices": [[
                    "Provider": "com.apple.wallpaper.choice.image",
                    "Files": [currentPath]
                ]]]]]]
            },
            screens: { [.init(id: 1, uuid: "D1", desktopImagePath: currentPath)] },
            aerialSearchDirs: [],
            checkReadable: { p in
                checkedPaths.append(p)
                return simulateAllowed ? .readable : .permissionDenied
            },
            onAlert: { alerts.append($0) }
        )

        let (ud, suite) = PausaDefaults.makeIsolated()
        defer { ud.removePersistentDomain(forName: suite) }
        let s = Settings(defaults: ud)
        XCTAssertEqual(s.theme, .random)   // Desktop wasn't authorized yet

        // 1. User clicks 系统壁纸 in Settings -> denied -> shows permission alert and stays `.random`.
        SystemWallpaper.selectFromMenu(in: nil, settings: s, defaults: ud)
        XCTAssertEqual(alerts, [.permissionNeeded])
        XCTAssertEqual(s.theme, .random)
        XCTAssertTrue(SystemWallpaper.authorizedBuckets(in: ud).isEmpty)

        // 2. User grants Desktop permission and clicks 系统壁纸 again -> switches to `.systemWallpaper`!
        alerts.removeAll()
        simulateAllowed = true
        SystemWallpaper.selectFromMenu(in: nil, settings: s, defaults: ud)
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertEqual(s.theme, .systemWallpaper)
        XCTAssertEqual(SystemWallpaper.authorizedBuckets(in: ud), [.desktop])

        // 3. Long break runs with Desktop authorized -> decodes bright image and computes positive extraDim!
        SystemWallpaper.prepare(long: true, seed: 1, night: false, settings: s, defaults: ud)
        guard case .image(let decoded, let extraDim) = SystemWallpaper.backdrop(for: 1) else {
            return XCTFail("Expected decoded image backdrop")
        }
        XCTAssertEqual(decoded.width, 160)
        XCTAssertGreaterThan(extraDim, 0.3)

        // 4. Later, user changes macOS wallpaper to ~/Downloads/other.png (`.downloads` NOT authorized).
        //    Automatic break must NOT probe ~/Downloads/other.png, and must revert theme to `.random`.
        checkedPaths.removeAll()
        currentPath = downloadsImg.path
        SystemWallpaper.prepare(long: true, seed: 2, night: false, settings: s, defaults: ud)
        XCTAssertTrue(checkedPaths.isEmpty, "Automatic break must not touch un-authorized Downloads folder")
        XCTAssertEqual(s.theme, .random)
    }

    // MARK: - 5. Dynamic Multi-Frame HEIC & Plan B Aerial Video Playback Lifecycle

    func testDynamicHEICDayNightSelectionAndAerialVideoPlayerLifecycle() async throws {
        // 1. 2-frame HEIC: frame 0 = pure white (day), frame 1 = black (night).
        let dynURL = tempDir.appendingPathComponent("dynamic.heic")
        try writeImages(
            [makeSolidImage(r: 1, g: 1, b: 1), makeSolidImage(r: 0, g: 0, b: 0)],
            type: .heic,
            to: dynURL
        )
        let dayDecoded = try XCTUnwrap(SystemWallpaper.decodeImageAndContrast(url: dynURL, night: false, px: 320, aspect: 1.6))
        let nightDecoded = try XCTUnwrap(SystemWallpaper.decodeImageAndContrast(url: dynURL, night: true, px: 320, aspect: 1.6))
        XCTAssertGreaterThan(dayDecoded.extraDim, 0.3, "Day frame (white) requires extraDim")
        XCTAssertEqual(nightDecoded.extraDim, 0, accuracy: 0.01, "Night frame (black) needs 0 extraDim")

        // 2. Plan B Aerial `.mov` resolution (fixed assetID & shuffle) + AVQueuePlayer safety invariants.
        let aerialDir = tempDir.appendingPathComponent("videos", isDirectory: true)
        try FileManager.default.createDirectory(at: aerialDir, withIntermediateDirectories: true)
        let movURL = aerialDir.appendingPathComponent("ASSET-42.mov")
        try await writeTinyMOV(to: movURL, r: 240, g: 245, b: 250)

        XCTAssertEqual(SystemWallpaper.findAerialVideo(assetID: "ASSET-42", seed: 1, dirs: [aerialDir.path]), movURL)
        XCTAssertEqual(SystemWallpaper.findAerialVideo(assetID: nil, seed: 99, dirs: [aerialDir.path]), movURL)

        let cfg = try encodeConfigPlist(["assetID": "ASSET-42"])
        SystemWallpaper.probeOverride = .init(
            homeDirectory: tempDir.path,
            loadIndexPlist: {
                ["AllSpacesAndDisplays": ["Linked": ["Content": ["Choices": [[
                    "Provider": "com.apple.wallpaper.choice.aerials",
                    "Configuration": cfg
                ]]]]]]
            },
            screens: { [.init(id: 7, uuid: "DISP-7", desktopImagePath: nil)] },
            aerialSearchDirs: [aerialDir.path],
            checkReadable: { _ in .readable }
        )

        let (ud, suite) = PausaDefaults.makeIsolated()
        defer { ud.removePersistentDomain(forName: suite) }
        let s = Settings(defaults: ud)
        XCTAssertEqual(s.theme, .systemWallpaper)

        SystemWallpaper.prepare(long: true, seed: 1, night: false, settings: s, defaults: ud)
        guard case .video(let resolvedURL, let poster, let videoDim) = SystemWallpaper.backdrop(for: 7) else {
            return XCTFail("Expected .video backdrop for downloaded Aerial .mov")
        }
        XCTAssertEqual(resolvedURL, movURL)
        XCTAssertNotNil(poster)
        XCTAssertGreaterThan(videoDim, 0.2, "Bright aerial video frame must compute protective extraDim")

        // Verify AerialPlayerNSView sets muted + preventsDisplaySleepDuringVideoPlayback = false and releases on teardown.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 96), styleMask: [.borderless], backing: .buffered, defer: false)
        let playerView = AerialPlayerNSView(frame: NSRect(x: 0, y: 0, width: 160, height: 96))
        window.contentView = playerView
        playerView.configure(url: movURL, poster: poster)
        let queuePlayer = try XCTUnwrap(playerView.player)
        XCTAssertTrue(queuePlayer.isMuted)
        XCTAssertFalse(queuePlayer.preventsDisplaySleepDuringVideoPlayback)

        // Removing from window (same as BreakOverlayController setting `w.contentView = nil`) tears down decoder immediately.
        window.contentView = nil
        XCTAssertNil(playerView.player)
    }
}
