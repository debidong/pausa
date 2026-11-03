import AppKit
import ImageIO
import PausaCore
import UniformTypeIdentifiers

/// 我的照片 import (spec §3.3), run once when the user picks a file: decode once (at most 3840 px,
/// upright), redraw in sRGB on black, measure photoExtraDim (§3.5), write a metadata-free JPEG copy
/// into Pausa's own folder, then store photoExtraDim and only then theme = .photo. No UI here: the
/// caller gets an Outcome and shows the alert (§3.6). Any failure leaves the old copy, the old
/// photoExtraDim and the theme as they were, and no temp file.
enum PhotoImport {
    enum Failure: Error, Equatable {
        case unreadable      // no source, or not completely readable (corrupt, truncated)
        case unsupportedType // not JPEG / PNG / HEIC inside, whatever the extension says
        case multipleImages  // animated PNG, HEIC sequence, burst
        case decode          // thumbnail or redraw failed
        case write           // folder, encode or replace failed
    }
    enum Outcome: Equatable {
        case success(extraDim: Double)
        case failure(Failure)
    }

    static let maxPixelSize = 3840
    static let jpegQuality = 0.9
    static let fileName = "my-photo.jpg"
    static let tempName = "my-photo.tmp.jpg"
    static let extraDimKey = "photoExtraDim"
    static let allowedTypes: Set<String> = [UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier]

    /// ~/Library/Application Support/<appName>/ (the dev build keeps its own, like BreakLog).
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
    }
    static var photoURL: URL { directory.appendingPathComponent(fileName) }

    /// Width / height of the reference screen: the one with the longest side in pixels, the same rule as
    /// SceneryArt.targetPixels (§3.5). 16:10 without a screen.
    @MainActor static var referenceAspect: Double {
        let s = NSScreen.screens.max { a, b in
            max(a.frame.width, a.frame.height) * a.backingScaleFactor < max(b.frame.width, b.frame.height) * b.backingScaleFactor
        }
        guard let f = s?.frame, f.height > 0 else { return 16.0 / 10.0 }
        return f.width / f.height
    }

    /// Imports on a background queue; `completion` runs on the main queue after photoExtraDim and then
    /// the theme are written (success only).
    @MainActor static func run(_ url: URL, completion: @escaping (Outcome) -> Void) {
        let aspect = referenceAspect
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = importPhoto(url, aspect: aspect)
            DispatchQueue.main.async {
                if case .success(let dim) = outcome {
                    UserDefaults.standard.set(dim, forKey: extraDimKey)
                    Settings.shared.theme = .photo   // last (§3.3 step 7)
                }
                completion(outcome)
            }
        }
    }

    /// Steps 1–6 and 8, synchronous (call off the main thread). Writes `dir`/my-photo.jpg; does not
    /// touch UserDefaults or the theme.
    static func importPhoto(_ url: URL, aspect: Double, into dir: URL = directory) -> Outcome {
        // 1–2. Source must be complete, really JPEG/PNG/HEIC, one image.
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(src) == .statusComplete else { return .failure(.unreadable) }
        guard let type = CGImageSourceGetType(src) as String?, allowedTypes.contains(type) else { return .failure(.unsupportedType) }
        let count = CGImageSourceGetCount(src)
        guard count <= 1 else { return .failure(.multipleImages) }
        guard count == 1 else { return .failure(.unreadable) }
        // 3. Decode once: at most 3840 px on the long side (never upscaled), EXIF orientation applied.
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return .failure(.decode) }
        // 4. sRGB, 8 bit, no alpha: fill opaque black first, then draw (transparent PNG lands on black).
        let w = thumb.width, h = thumb.height, rb = w * 4
        guard w > 0, h > 0, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: rb, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return .failure(.decode) }
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = ctx.makeImage(), let data = ctx.data else { return .failure(.decode) }
        // 5. Contrast (§3.5) on the redrawn RGBX bytes (row 0 is the top row in memory).
        let rowBytes = ctx.bytesPerRow
        let pixels = [UInt8](UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: rowBytes * h))
        let dim = PhotoContrast.measure(pixels: pixels, width: w, height: h, bytesPerPixel: 4, rowBytes: rowBytes, aspect: aspect).extraDim
        // 6. JPEG q 0.9, no metadata, to my-photo.tmp.jpg, then atomically over my-photo.jpg.
        let fm = FileManager.default
        let tmp = dir.appendingPathComponent(tempName), dst = dir.appendingPathComponent(fileName)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.removeItem(at: tmp)
            guard let out = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.write }
            CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
            guard CGImageDestinationFinalize(out) else { throw Failure.write }
            if fm.fileExists(atPath: dst.path) {
                _ = try fm.replaceItemAt(dst, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dst)
            }
        } catch {
            try? fm.removeItem(at: tmp)   // 8. never leave the temp file
            return .failure(.write)
        }
        return .success(extraDim: dim)
    }
}
