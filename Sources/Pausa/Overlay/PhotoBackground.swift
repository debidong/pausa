import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import os
import PausaCore

/// 我的照片 (spec §3): choosing a photo (panel, import, alert) and showing it on the long break.
/// The import itself is PhotoImport; this file is the UI around it and the break-time decode.
enum PhotoBackground {
    private static let log = Logger(subsystem: "app.pausa", category: "scenery")

    // MARK: Choosing (§3.1, §3.2, §3.6)

    /// 我的照片… in the theme menu, every time it is chosen (also when it is already the theme): the
    /// open panel as a sheet on `window`. Cancel changes nothing. A good file is imported off the main
    /// thread and only then becomes the theme; a bad one shows the alert and changes nothing.
    @MainActor static func choose(in window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // First time ~/Pictures; after that the panel's own remembered folder.
        if UserDefaults.standard.object(forKey: "NSNavLastRootDirectory") == nil {
            panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        }
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            PhotoImport.run(url) { outcome in
                if case .failure = outcome { showImportFailed(in: window) }
            }
        }
        if let window, window.isVisible { panel.beginSheetModal(for: window, completionHandler: done) }
        else { panel.begin(completionHandler: done) }
    }

    /// 「无法使用这张图片」 with one 好 button; no detail, no reason (§3.6).
    @MainActor static func showImportFailed(in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("photo.importFailed")
        alert.addButton(withTitle: L("common.ok"))
        if let window, window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: Showing (§3.4, §3.7)

    /// Debug renders only: this file and dim instead of the imported photo and photoExtraDim.
    static var override: (url: URL, extraDim: Double)?
    static var url: URL { override?.url ?? PhotoImport.photoURL }
    /// Black layer stored at import (§3.5), 0…0.55.
    static var extraDim: Double {
        override?.extraDim ?? min(PhotoContrast.cap, max(0, UserDefaults.standard.double(forKey: PhotoImport.extraDimKey)))
    }

    /// This long break could not read the photo: ThemeChoice.current shows the random scene instead.
    /// Decided once when a break opens; the setting itself stays 我的照片….
    private(set) static var fallback = false

    /// Call when a break opens (after RandomScene.roll). Long break with 我的照片… selected: decode
    /// now, and fall back to random for this break if that fails.
    static func prepare(long: Bool) {
        fallback = false
        guard long, Settings.shared.theme == .photo else { return }
        if image(px: SceneryArt.targetPixels) == nil {
            fallback = true
            log.notice("my-photo unavailable, using random")
        }
    }

    private static var cache: (key: String, image: CGImage)?
    /// The imported copy, decoded to at most `px` on the long side, as is (no oil paint). Cached by
    /// path + modification date + px, so a new import is picked up. nil if missing or unreadable.
    static func image(px: Int) -> CGImage? {
        let u = url
        guard let m = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date else {
            cache = nil; return nil
        }
        let key = "\(u.path)|\(m.timeIntervalSinceReferenceDate)|\(px)"
        if let c = cache, c.key == key { return c.image }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: px,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true]
        guard let src = CGImageSourceCreateWithURL(u as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(src) == .statusComplete,
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { cache = nil; return nil }
        cache = (key, img)
        return img
    }
}

/// The photo on one screen: cover-fit (fills, centred, cropped), no pan, no animation. Then the
/// black photoExtraDim, then the same day / night dim as the painted scenes. Midnight's extra dim
/// is LongBreakView's, on top of this.
struct PhotoBackdrop: View {
    let image: CGImage
    let extraDim: Double
    let night: Bool
    var body: some View {
        ZStack {
            Canvas(rendersAsynchronously: false) { ctx, size in
                let iw = CGFloat(image.width), ih = CGFloat(image.height)
                let s = max(size.width / iw, size.height / ih)
                let rect = CGRect(x: (size.width - iw * s) / 2, y: (size.height - ih * s) / 2, width: iw * s, height: ih * s)
                ctx.draw(Image(decorative: image, scale: 1), in: rect)
            }
            Color.black.opacity(extraDim)
            Color.black.opacity(night ? SceneryArt.nightDim : SceneryArt.dayDim)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
