import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Pausa
@testable import PausaCore

@MainActor
final class PhotoImportAndBackgroundTests: XCTestCase {
    private var tempDir: URL!
    private var savedTheme: ThemeChoice!

    override func setUpWithError() throws {
        try super.setUpWithError()
        Settings.dryRun = true
        savedTheme = Settings.shared.theme
        PhotoBackground.override = nil
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pausa-photo-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        PhotoBackground.override = nil
        if let savedTheme { Settings.shared.theme = savedTheme }
        Settings.dryRun = false
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    private func makeSolidCGImage(width: Int, height: Int, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1.0) throws -> CGImage {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ctx = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ))
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: a))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func writeImages(_ images: [CGImage], type: UTType, to url: URL) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil))
        for img in images {
            CGImageDestinationAddImage(dest, img, nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    func testImportPhotoRejectsMissingCorruptUnsupportedAndMultiFrameFiles() throws {
        let outDir = tempDir.appendingPathComponent("out", isDirectory: true)

        // 1. Non-existent file -> .unreadable
        let missingURL = tempDir.appendingPathComponent("missing.jpg")
        XCTAssertEqual(PhotoImport.importPhoto(missingURL, aspect: 1.6, into: outDir), .failure(.unreadable))

        // 2a. Non-image garbage bytes -> .unreadable
        let garbageURL = tempDir.appendingPathComponent("garbage.bin")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: garbageURL)
        XCTAssertEqual(PhotoImport.importPhoto(garbageURL, aspect: 1.6, into: outDir), .failure(.unreadable))

        // 2b. Truncated JPEG SOI header (recognized container, un-decodable payload) -> .decode
        let corruptURL = tempDir.appendingPathComponent("corrupt.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0x00, 0x12]).write(to: corruptURL)
        XCTAssertEqual(PhotoImport.importPhoto(corruptURL, aspect: 1.6, into: outDir), .failure(.decode))

        // 3. Valid TIFF image disguised with a .jpg extension -> .unsupportedType (content-type check, not extension)
        let disguisedTIFF = tempDir.appendingPathComponent("fake.jpg")
        let sample = try makeSolidCGImage(width: 64, height: 64, r: 0.2, g: 0.4, b: 0.6)
        try writeImages([sample], type: .tiff, to: disguisedTIFF)
        XCTAssertEqual(PhotoImport.importPhoto(disguisedTIFF, aspect: 1.6, into: outDir), .failure(.unsupportedType))

        // 4. Multi-image PNG container (2 frames) -> .multipleImages
        let animatedPNG = tempDir.appendingPathComponent("two-frames.png")
        try writeImages([sample, sample], type: .png, to: animatedPNG)
        XCTAssertEqual(PhotoImport.importPhoto(animatedPNG, aspect: 1.6, into: outDir), .failure(.multipleImages))

        // None of the failed imports should leave my-photo.jpg or my-photo.tmp.jpg behind.
        XCTAssertFalse(FileManager.default.fileExists(atPath: outDir.appendingPathComponent(PhotoImport.fileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outDir.appendingPathComponent(PhotoImport.tempName).path))
    }

    func testImportPhotoMeasuresContrastDownscalesCompositesTransparencyAndReplacesAtomically() throws {
        let outDir = tempDir.appendingPathComponent("import-dir", isDirectory: true)
        let dstURL = outDir.appendingPathComponent(PhotoImport.fileName)
        let tmpURL = outDir.appendingPathComponent(PhotoImport.tempName)

        // 1. Pure white image requires positive extraDim (capped at PhotoContrast.cap).
        let whiteURL = tempDir.appendingPathComponent("bright.png")
        try writeImages([makeSolidCGImage(width: 400, height: 250, r: 1, g: 1, b: 1)], type: .png, to: whiteURL)
        let whiteOutcome = PhotoImport.importPhoto(whiteURL, aspect: 1.6, into: outDir)
        guard case .success(let brightDim) = whiteOutcome else {
            return XCTFail("Expected bright PNG import to succeed, got \(whiteOutcome)")
        }
        XCTAssertGreaterThan(brightDim, 0.3)
        XCTAssertLessThanOrEqual(brightDim, PhotoContrast.cap)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path))

        // 2. Oversized 4200x2100 dark image downscales to 3840x1920, produces extraDim == 0,
        //    and atomically replaces existing my-photo.jpg.
        let hugeDarkURL = tempDir.appendingPathComponent("huge-dark.png")
        try writeImages([makeSolidCGImage(width: 4200, height: 2100, r: 0, g: 0, b: 0)], type: .png, to: hugeDarkURL)
        let darkOutcome = PhotoImport.importPhoto(hugeDarkURL, aspect: 2.0, into: outDir)
        XCTAssertEqual(darkOutcome, .success(extraDim: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path))

        let src = try XCTUnwrap(CGImageSourceCreateWithURL(dstURL as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, PhotoImport.maxPixelSize)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, PhotoImport.maxPixelSize / 2)

        // 3. Fully transparent PNG composites onto opaque black, yielding extraDim == 0.
        let transparentURL = tempDir.appendingPathComponent("transparent.png")
        try writeImages([makeSolidCGImage(width: 200, height: 200, r: 1, g: 1, b: 1, a: 0)], type: .png, to: transparentURL)
        XCTAssertEqual(PhotoImport.importPhoto(transparentURL, aspect: 1.6, into: outDir), .success(extraDim: 0))

        // 4. Subsequent failed import preserves the previously imported good my-photo.jpg.
        let beforeData = try Data(contentsOf: dstURL)
        let badURL = tempDir.appendingPathComponent("bad.png")
        try Data("not an image".utf8).write(to: badURL)
        XCTAssertEqual(PhotoImport.importPhoto(badURL, aspect: 1.6, into: outDir), .failure(.unreadable))
        XCTAssertEqual(try Data(contentsOf: dstURL), beforeData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path))
    }

    func testPhotoBackgroundCacheInvalidationAndFallbackLifecycle() throws {
        let photoURL = tempDir.appendingPathComponent("custom.jpg")
        try writeImages([makeSolidCGImage(width: 800, height: 500, r: 0.1, g: 0.2, b: 0.3)], type: .jpeg, to: photoURL)

        PhotoBackground.override = (url: photoURL, extraDim: 0.25)
        XCTAssertEqual(PhotoBackground.url, photoURL)
        XCTAssertEqual(PhotoBackground.extraDim, 0.25, accuracy: 0.0001)

        // Decode at max 400 px on the long side and verify cache hit returns same dimensions.
        let first = try XCTUnwrap(PhotoBackground.image(px: 400))
        XCTAssertEqual(first.width, 400)
        XCTAssertEqual(first.height, 250)
        let cached = try XCTUnwrap(PhotoBackground.image(px: 400))
        XCTAssertEqual(cached.width, 400)

        // Replace file with a square image and bump modificationDate -> cache invalidates and decodes new geometry.
        try writeImages([makeSolidCGImage(width: 600, height: 600, r: 0.5, g: 0.5, b: 0.5)], type: .jpeg, to: photoURL)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: photoURL.path)
        let updated = try XCTUnwrap(PhotoBackground.image(px: 400))
        XCTAssertEqual(updated.width, 400)
        XCTAssertEqual(updated.height, 400)

        // With theme == .photo and valid image, prepare(long: true) keeps fallback == false.
        Settings.shared.theme = .photo
        PhotoBackground.prepare(long: true)
        XCTAssertFalse(PhotoBackground.fallback)

        // Delete backing photo -> image(px:) returns nil and prepare(long: true) flips fallback == true.
        try FileManager.default.removeItem(at: photoURL)
        XCTAssertNil(PhotoBackground.image(px: 400))
        PhotoBackground.prepare(long: true)
        XCTAssertTrue(PhotoBackground.fallback)

        // Short breaks reset fallback to false without needing the photo.
        PhotoBackground.prepare(long: false)
        XCTAssertFalse(PhotoBackground.fallback)
    }
}
