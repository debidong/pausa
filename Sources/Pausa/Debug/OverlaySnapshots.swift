#if DEBUG
import AppKit
import PausaCore
import SwiftUI

/// Offscreen render of the break views (no Screen Recording permission needed).
@MainActor
enum BreakViewSnapshots {
    static func write(to dir: URL) {
        for t in ThemeID.scenes {
            let short = ImageRenderer(content: ZStack(alignment: .center) {
                SnapshotDesktop().blur(radius: 30).clipped()
                Color.black.opacity(BreakOverlayController.shortDim)
                ShortBreakCapsule(countdown: Countdown(total: 20, onDone: {}), flatBackground: true, theme: t)
            }.frame(width: 1440, height: 900))
            save(short.nsImage, dir.appendingPathComponent("\(t.rawValue)-short.png"))
            let long = ImageRenderer(content: LongBreakView(countdown: Countdown(total: 180, onDone: {}),
                                                            showControls: true, onSnooze: { _ in },
                                                            theme: t, seed: 7, animate: false, stillTime: 60, night: false)
                .frame(width: 1440, height: 900))
            save(long.nsImage, dir.appendingPathComponent("\(t.rawValue)-long.png"))
            let longNight = ImageRenderer(content: LongBreakView(countdown: Countdown(total: 180, onDone: {}),
                                                                 showControls: true, onSnooze: { _ in },
                                                                 theme: t, seed: 7, animate: false, stillTime: 60, night: true)
                .frame(width: 1440, height: 900))
            save(longNight.nsImage, dir.appendingPathComponent("\(t.rawValue)-long-night.png"))
        }
    }

    /// Long break per theme at 16:10 and 16:9 with a fixed 2:47 countdown.
    static func writeLong(to dir: URL, night: Bool = false) {
        SceneryArt.override = 1920
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for t in ThemeID.scenes {
            for (tag, w, h) in [("1610", 1920.0, 1200.0), ("169", 1920.0, 1080.0)] {
                let r = ImageRenderer(content: LongBreakView(countdown: Countdown(total: 180, onDone: {}),
                                                             showControls: true, onSnooze: { _ in },
                                                             theme: t, seed: 7, animate: false, stillTime: 60,
                                                             night: night, fixedRemaining: 167, flatControls: true)
                    .frame(width: w, height: h))
                r.scale = 1
                save(r.nsImage, dir.appendingPathComponent("long-\(t.rawValue)\(night ? "-night" : "")-\(tag).png"))
            }
        }
        for (n, w) in [("medium", Font.Weight.medium), ("semibold", .semibold), ("bold", .bold)] where !night {
            LongBreakView.countdownWeight = w
            let r = ImageRenderer(content: LongBreakView(countdown: Countdown(total: 180, onDone: {}),
                                                         showControls: true, onSnooze: { _ in },
                                                         theme: .forest, seed: 7, animate: false, stillTime: 60,
                                                         night: false, fixedRemaining: 167)
                .frame(width: 1920, height: 1200))
            r.scale = 1
            save(r.nsImage, dir.appendingPathComponent("long-forest-w-\(n).png"))
        }
        LongBreakView.countdownWeight = .semibold
        var locked = LongBreakView(countdown: Countdown(total: 180, onDone: {}),
                                   showControls: true, onSnooze: { _ in },
                                   theme: .forest, seed: 7, animate: false, stillTime: 60,
                                   night: night, fixedRemaining: 167, flatControls: true)
        locked.locked = true
        locked.onUrgent = {}
        let rl = ImageRenderer(content: locked.frame(width: 1920, height: 1200))
        rl.scale = 1
        save(rl.nsImage, dir.appendingPathComponent("long-forest-locked\(night ? "-night" : "").png"))
        SceneryArt.override = nil
    }

    static func writeLongPhoto(to dir: URL, photos: [String]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pausa-photo-render-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? FileManager.default.removeItem(at: tmp); PhotoBackground.override = nil; SceneryArt.override = nil }
        SceneryArt.override = 1920
        for path in photos {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let into = tmp.appendingPathComponent(name)
            guard case .success(let dim) = PhotoImport.importPhoto(URL(fileURLWithPath: path), aspect: 16.0 / 10.0, into: into) else {
                print("\(name): import failed"); continue
            }
            PhotoBackground.override = (into.appendingPathComponent(PhotoImport.fileName), dim)
            func view(_ w: Double, _ h: Double, night: Bool, _ part: BreakDaypart, bare: Bool = false) -> some View {
                var v = LongBreakView(countdown: Countdown(total: 180, onDone: {}), showControls: true, onSnooze: { _ in },
                                      theme: .photo, seed: 7, animate: false, stillTime: 60, night: night, daypart: part,
                                      fixedRemaining: 167, flatControls: true, quote: RestQuotes.all.first?.text(for: AppLanguage.current))
                v.bare = bare
                return v.frame(width: w, height: h)
            }
            for (tag, w, h) in [("1610", 1920.0, 1200.0), ("169", 1920.0, 1080.0), ("219", 2520.0, 1080.0)] {
                let r = ImageRenderer(content: view(w, h, night: false, .day)); r.scale = 1
                save(r.nsImage, dir.appendingPathComponent("long-photo-\(name)-\(tag).png"))
            }
            for (tag, night, part) in [("night", true, BreakDaypart.night), ("midnight", true, .midnight)] {
                let r = ImageRenderer(content: view(1920, 1200, night: night, part)); r.scale = 1
                save(r.nsImage, dir.appendingPathComponent("long-photo-\(name)-1610-\(tag).png"))
            }
            let bare = ImageRenderer(content: view(1920, 1200, night: false, .day, bare: true)); bare.scale = 1
            if let cg = bare.cgImage, let c = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                                        bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) {
                c.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                let px = [UInt8](UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: c.bytesPerRow * cg.height))
                let m = PhotoContrast.measure(pixels: px, width: cg.width, height: cg.height, rowBytes: c.bytesPerRow, aspect: 1.6)
                print(String(format: "%@: photoExtraDim %.2f, drawn text-zone Y95 %.4f, white text %.2f:1", name, dim, m.y95, 1.05 / (m.y95 + 0.05)))
            }
        }
    }

    static func writeQuotes(to dir: URL, lang: String) {
        SceneryArt.override = 1920
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let longestAll = RestQuotes.all.compactMap { $0.text(for: AppLanguage.current) }.max { $0.count < $1.count }
        for (name, light) in [("light", true), ("dark", false)] {
            let r = ImageRenderer(content: ZStack {
                (light ? AnyView(LinearGradient(colors: [Color(white: 0.96), Color(red: 0.85, green: 0.9, blue: 0.97)], startPoint: .top, endPoint: .bottom))
                       : AnyView(SnapshotDesktop()))
                    .frame(width: 1440, height: 900).blur(radius: 30, opaque: true).clipped()
                Color.black.opacity(BreakOverlayController.shortDim)
                ShortBreakCapsule(countdown: Countdown(total: 20, onDone: {}), flatBackground: true, fixedRemaining: 18)
            }.frame(width: 1440, height: 900))
            save(r.nsImage, dir.appendingPathComponent("short-\(lang)-\(name).png"))
            let l = ImageRenderer(content: LongBreakView(countdown: Countdown(total: 300, onDone: {}),
                                                         showControls: true, onSnooze: { _ in },
                                                         theme: .forest, seed: 7, animate: false, stillTime: 60,
                                                         night: !light, fixedRemaining: 287, flatControls: true, quote: longestAll)
                .frame(width: 1920, height: 1200))
            l.scale = 1
            save(l.nsImage, dir.appendingPathComponent("long-\(lang)-\(name).png"))
        }
        for t in [ThemeID.ocean] {
            let l = ImageRenderer(content: LongBreakView(countdown: Countdown(total: 300, onDone: {}),
                                                         showControls: true, onSnooze: { _ in },
                                                         theme: t, seed: 7, animate: false, stillTime: 60,
                                                         night: false, fixedRemaining: 287, flatControls: true, quote: longestAll)
                .frame(width: 1920, height: 1200))
            l.scale = 1
            save(l.nsImage, dir.appendingPathComponent("long-\(lang)-\(t.rawValue).png"))
        }
        SceneryArt.override = nil
    }

    static func writeShortBlur(to url: URL, sample: NSImage?, opacity: Double = 1) {
        let r = ImageRenderer(content: ZStack {
            Group {
                if let sample { Image(nsImage: sample).resizable().scaledToFill() } else { SnapshotDesktop() }
            }
            .frame(width: 1440, height: 900).blur(radius: 30, opaque: true).clipped()
            Color.black.opacity(BreakOverlayController.shortDim)
            ShortBreakCapsule(countdown: Countdown(total: 20, onDone: {}), flatBackground: true,
                              fixedRemaining: 19).opacity(opacity)
        }.frame(width: 1440, height: 900))
        save(r.nsImage, url)
    }

    private static func save(_ img: NSImage?, _ url: URL) {
        guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("render failed: \(url.lastPathComponent)"); return }
        try? png.write(to: url)
        print("wrote \(url.path)")
    }
}

/// Busy fake desktop (windows, text bars) used under the blur in renders.
private struct SnapshotDesktop: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.blue, .purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
            ForEach(0..<6, id: \.self) { i in
                RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.9))
                    .frame(width: 420, height: 280)
                    .overlay(VStack(alignment: .leading, spacing: 10) {
                        ForEach(0..<8, id: \.self) { _ in Capsule().fill(Color.gray.opacity(0.6)).frame(height: 10) }
                    }.padding(24))
                    .offset(x: CGFloat(80 + i * 210), y: CGFloat(60 + (i % 3) * 250))
            }
        }
        .frame(width: 1440, height: 900)
    }
}

/// The panel as one SwiftUI picture, for renders: shadow, black, then the content.
struct PreBreakComposite: View {
    @ObservedObject var model: PreBreakModel
    var placement: PanelPlacement
    var height: CGFloat
    var body: some View {
        ZStack(alignment: .top) {
            PanelShape().fill(Color.black)
                .frame(width: PanelMetrics.width, height: height)
                .shadow(color: .black.opacity(Double(PanelMetrics.shadowOpacity)), radius: PanelMetrics.shadowRadius, x: 0, y: PanelMetrics.shadowY)
            PreBreakContentView(model: model, topRow: placement.topRow)
        }
        .frame(width: PanelMetrics.width, height: height, alignment: .top)
    }
}

@MainActor
enum PreBreakSnapshots {
    static let backdrop = Color(red: 0x1B / 255, green: 0x1B / 255, blue: 0x1D / 255)

    static func state(_ kind: BreakKind, snooze: PreBreakState.Snooze, hardLine: Bool = false, seconds: Int = 24) -> PreBreakState {
        PreBreakState(kind: kind, secondsLeft: seconds, snooze: snooze, canSkip: kind == .short && !hardLine,
                      atHardLine: hardLine, typingWait: false, showCard: true, showPill: false)
    }

    static let cases: [(String, PreBreakState)] = [
        ("short", state(.short, snooze: .available(minutes: 5))),
        ("short-usedup", state(.short, snooze: .usedUp)),
        ("long", state(.long, snooze: .available(minutes: 5))),
        ("90min", state(.long, snooze: .hidden, hardLine: true)),
    ]

    static func png<V: View>(_ view: V, to url: URL) {
        let host = NSHostingView(rootView: view.environment(\.locale, AppLanguage.current.locale))
        host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { print("render failed: \(url.lastPathComponent)"); return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { print("render failed: \(url.lastPathComponent)"); return }
        try? data.write(to: url)
        print("wrote \(url.path)")
    }

    static func panelHeight(_ s: PreBreakState, topRow: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: PreBreakContentView(model: PreBreakModel(s), topRow: topRow))
        return ceil(host.fittingSize.height)
    }

    static func scene(_ s: PreBreakState, notch: Bool) -> some View {
        let placement = PanelPlacement(hasNotch: notch, topRow: 32, centerX: 0, notchWidth: notch ? 185 : nil)
        let h = panelHeight(s, topRow: 32)
        return ZStack(alignment: .top) {
            backdrop
            if notch {
                PanelShape(radius: PanelMetrics.notchRadius).fill(Color.black).frame(width: 185, height: 32)
            }
            PreBreakComposite(model: PreBreakModel(s), placement: placement, height: h)
        }
        .frame(width: PanelMetrics.width + 2 * 56, height: h + 80, alignment: .top)
    }

    static func writePanels(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let saved = AppLanguage.override
        defer { AppLanguage.override = saved }
        for (lang, tag) in [(AppLanguage.zhHans, "zh"), (.en, "en")] {
            AppLanguage.override = lang
            for notch in [true, false] {
                for (stem, st) in cases {
                    png(scene(st, notch: notch), to: dir.appendingPathComponent("\(tag)-\(notch ? "notch" : "nonotch")-\(stem).png"))
                }
            }
        }
    }

    /// Window-free checks (spec 12.3).
    static func selftest() -> Bool {
        var ok = true
        func check(_ c: Bool, _ name: String) { print(c ? "ok   \(name)" : "FAIL \(name)"); ok = ok && c }
        let saved = AppLanguage.override
        defer { AppLanguage.override = saved }

        let sf = NSRect(x: 0, y: 0, width: 1440, height: 900), size = NSSize(width: 140, height: 46)
        let mid = PreBreakController.pillFrame(mouse: NSPoint(x: 700, y: 450), size: size, in: sf)
        check(mid.minX == 704 && mid.maxY == 442, "pill sits at (+16, −20) from the pointer")
        let corner = PreBreakController.pillFrame(mouse: NSPoint(x: 1435, y: 3), size: size, in: sf)
        check(sf.contains(corner) && corner.maxX <= 1435 && corner.minY >= 3, "pill flips left and up in the bottom-right corner")
        let second = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        check(second.contains(PreBreakController.pillFrame(mouse: NSPoint(x: 1441, y: 1079), size: size, in: second)),
              "pill stays inside the pointer's screen")

        let c = cases.map { $0.1 }
        check(PanelButton.set(for: c[0]) == [.skip, .snooze(5), .now], "S1: skip · snooze · now")
        check(PanelButton.set(for: c[1]) == [.skip, .snoozeUsedUp, .now], "S2: skip · can't snooze · now")
        check(PanelButton.set(for: c[2]) == [.snooze(5), .now], "S3: snooze · now")
        check(PanelButton.set(for: state(.long, snooze: .usedUp)) == [.snoozeUsedUp, .now], "S4: can't snooze · now")
        check(PanelButton.set(for: c[3]) == [.urgent, .now], "S5: urgent · now")

        AppLanguage.override = .en
        let enS2 = RowLayout.choose(PanelButton.set(for: c[1]))
        print("     en S2 single-row width \(RowLayout.width(of: PanelButton.set(for: c[1])))")
        check(enS2 == .noteBelow, "English S2 uses the note-below layout")
        AppLanguage.override = .zhHans
        check(RowLayout.choose(PanelButton.set(for: c[1])) == .single, "Chinese S2 stays on one row")
        check(RowLayout.choose(PanelButton.set(for: c[0])) == .single, "Chinese S1 stays on one row")

        var widths = Set<CGFloat>()
        for lang in [AppLanguage.zhHans, .en] {
            AppLanguage.override = lang
            for (_, st) in cases {
                let host = NSHostingView(rootView: PreBreakContentView(model: PreBreakModel(st), topRow: 32))
                widths.insert(host.fittingSize.width)
            }
        }
        check(widths == [PanelMetrics.width], "content is 360 pt wide in every state and language (\(widths))")

        AppLanguage.override = .zhHans
        let h32 = panelHeight(c[0], topRow: 32), h38 = panelHeight(c[0], topRow: 38)
        check(h38 - h32 == 6, "a 38 pt notch makes the panel 6 pt taller than a 32 pt one")
        func notch(_ top: CGFloat, w: CGFloat) -> PanelPlacement {
            let f = NSRect(x: 0, y: 0, width: 1512, height: 982), mid = f.midX
            return .compute(frame: f, safeTop: top,
                            auxLeft: NSRect(x: 0, y: 950, width: mid - w / 2, height: top),
                            auxRight: NSRect(x: mid + w / 2, y: 950, width: mid - w / 2, height: top))
        }
        check(notch(32, w: 185).topRow == 32 && notch(38, w: 185).topRow == 38, "blank row equals safeAreaInsets.top")
        check(notch(32, w: 185).centerX == 756 && notch(32, w: 185).notchWidth == 185, "centre and width come from the aux areas")
        let wide = notch(32, w: 360)
        check(!wide.hasNotch && wide.topRow == 32 && wide.centerX == 756, "a 360 pt notch is treated as no notch")
        let none = PanelPlacement.compute(frame: NSRect(x: 100, y: 0, width: 1000, height: 800), safeTop: 0, auxLeft: nil, auxRight: nil)
        check(!none.hasNotch && none.centerX == 600 && none.topRow == 32, "no notch: centred on the screen, 32 pt blank row")

        for lang in [AppLanguage.zhHans, .en] {
            AppLanguage.override = lang
            let a = NSHostingView(rootView: PanelSentence(kind: .short, seconds: 10)).fittingSize.width
            let b = NSHostingView(rootView: PanelSentence(kind: .short, seconds: 9)).fittingSize.width
            check(abs(a - b) <= 0.5, "\(lang.rawValue): 10 → 9 moves the sentence by \(abs(a - b)) pt (≤ 0.5)")
        }
        let p1 = PanelPath.make(CGRect(x: 0, y: 0, width: 185, height: 32), radius: 10, yUp: true)
        let p2 = PanelPath.make(CGRect(x: 0, y: 0, width: 360, height: 170), radius: 24, yUp: true)
        func count(_ p: CGPath) -> Int { var n = 0; p.applyWithBlock { _ in n += 1 }; return n }
        check(count(p1) == count(p2), "start and end outlines have the same structure")
        return ok
    }
}
#endif
