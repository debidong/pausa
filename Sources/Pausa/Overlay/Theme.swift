import os
import CoreImage
import SwiftUI
import AppKit
import ImageIO

/// v0.2 themes. Accents are system colors (HIG), never literal hex, so light/dark/
/// increased-contrast variants come for free. Scenery is original pixel art drawn here.
/// Mitchell's `ThemeChoice` (Settings) is the source of truth; this file adds colors + scenery.
typealias ThemeID = ThemeChoice

extension ThemeChoice {
    var accentNS: NSColor {
        switch self {
        case .forest: return .systemGreen
        case .ocean: return .systemTeal
        case .sunset: return .systemOrange
        case .night: return .systemIndigo
        case .random: return .controlAccentColor   // the scene changes per break; controls use the system accent
        }
    }

    var accent: Color { self == .random ? .accentColor : Color(nsColor: accentNS) }

    /// The scene on screen: the chosen theme, or for 随机 the scene rolled for this break.
    static var current: ThemeChoice {
        let t = Settings.shared.theme
        return t == .random ? RandomScene.current : t
    }
}

/// 随机: one scene per break, never the same as the previous break. The last pick is kept across launches.
enum RandomScene {
    private static let key = "randomSceneLast"
    static var current: ThemeChoice {
        ThemeChoice(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .forest
    }
    /// Call when a break starts. No-op unless 随机 is selected.
    static func roll() {
        guard Settings.shared.theme == .random else { return }
        let next = pick(after: current)
        UserDefaults.standard.set(next.rawValue, forKey: key)
    }
    static func pick(after last: ThemeChoice?, using g: inout some RandomNumberGenerator) -> ThemeChoice {
        ThemeChoice.scenes.filter { $0 != last }.randomElement(using: &g)!
    }
    static func pick(after last: ThemeChoice?) -> ThemeChoice {
        var g = SystemRandomNumberGenerator(); return pick(after: last, using: &g)
    }
}

/// Single app-wide accent. Use this, never a literal color.
enum Theme {
    static var accent: Color { ThemeID.current.accent }
    static var accentNS: NSColor { ThemeID.current.accentNS }
    /// Locale for overlay views (picks PingFang SC vs TC glyphs via system font fallback).
    // TODO(Mitchell): return the in-app language setting once it lands; Locale.current until then.
    static var appLocale: Locale { AppLanguage.current.locale }
}

// MARK: - Pixel scenery (v2: 320×180, Bayer-dithered, nearest-neighbor upscaled)
//
// Health rules (华佗/Steve): no flashing, no twinkling, no brightness jumps. The only
// motion is slow translation/rotation, long breaks only, all of it off under Reduce Motion.

enum Scenery {
    static let w = 320, h = 180

    /// "It's dark": system Dark appearance, or local time 20:00–07:00. Night Shift is not used:
    /// its state is only readable through private CoreBrightness, not a public API.
    static func isNight(now: Date = Date()) -> Bool {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let hour = Calendar.current.component(.hour, from: now)
        return dark || hour >= 20 || hour < 7
    }
    typealias RGB = (Double, Double, Double)

    enum Motion {
        case none
        case driftX(Double)                          // scene px/s, wraps horizontally
        case driftY(Double, clipTop: Double)         // scene px/s, wraps vertically below clipTop
        case sink(Double, over: Double)              // move down N px across `over` seconds
        case rotate(Double, pivot: CGPoint)          // degrees/s around pivot (scene coords)
    }
    struct Layer { let image: CGImage; var origin = CGPoint.zero; var motion = Motion.none }
    struct Sprite { let rect: CGRect; let color: Color }  // scene coords
    struct Scene {
        let layers: [Layer]
        let sprites: (Double) -> [Sprite]
        /// Motion clock: a scene is built when its break starts (new seed per break).
        let born = Date()
    }

    private static var cache: [String: Scene] = [:]

    /// Built once per theme+seed; a new break passes a new seed (positions/timing vary).
    static func scene(_ t: ThemeID, seed: UInt64) -> Scene {
        let key = "\(t.rawValue).\(seed)"
        if let s = cache[key] { return s }
        if cache.count > 8 { cache.removeAll() }
        let s = build(t, seed)
        cache[key] = s
        return s
    }

    // MARK: pixel buffer

    struct Pix {
        let w: Int, h: Int
        var buf: [Double]
        init(_ w: Int = Scenery.w, _ h: Int = Scenery.h) { self.w = w; self.h = h; buf = .init(repeating: 0, count: w * h * 4) }
        mutating func blend(_ x: Int, _ y: Int, _ c: RGB, _ a: Double = 1) {
            guard x >= 0, y >= 0, x < w, y < h, a > 0 else { return }
            let i = (y * w + x) * 4
            buf[i] = c.0 * a + buf[i] * (1 - a); buf[i+1] = c.1 * a + buf[i+1] * (1 - a)
            buf[i+2] = c.2 * a + buf[i+2] * (1 - a); buf[i+3] = 255 * a + buf[i+3] * (1 - a)
        }
        func image() -> CGImage {
            let bytes = buf.map { UInt8(max(0, min(255, $0.rounded()))) }
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            bytes.withUnsafeBytes { ctx.data!.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
            return ctx.makeImage()!
        }
    }

    private static let bayer: [[Double]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
    private static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }
    /// Ordered-dither gradient between `steps` bands.
    private static func dgrad(_ p: inout Pix, y0: Int, y1: Int, _ a: RGB, _ b: RGB, steps: Int) {
        for y in y0..<y1 {
            let t = Double(y - y0) / Double(max(1, y1 - y0)) * Double(steps - 1)
            let i = Int(t), f = t - Double(i)
            let c0 = mix(a, b, Double(i) / Double(steps - 1)), c1 = mix(a, b, Double(min(i + 1, steps - 1)) / Double(steps - 1))
            for x in 0..<p.w { p.blend(x, y, f * 16 > bayer[y % 4][x % 4] ? c1 : c0) }
        }
    }
    /// Smooth fractal ridge; the crest gets a lit rim and a dithered 2-px fade into the sky (soft edge).
    /// `tilt` runs the ridge diagonally (px per px), `peak` adds one dominant summit at that x.
    private static func mountain(_ p: inout Pix, _ r: inout LCG, base: Double, amp: Double, _ col: RGB, lit: RGB,
                                 tilt: Double = 0, peak: Double? = nil) {
        let ph = (0..<6).map { _ in r.unit() * 6.28 }
        // 5 octaves (not 6): the finest one is what made stair-step jaggies at 320 px.
        func n(_ x: Double) -> Double { (0..<5).reduce(0) { $0 + pow(0.5, Double($1)) * sin(x * 0.01 * pow(2, Double($1)) + ph[$1]) } }
        func f(_ x: Double) -> Double {
            let pk = peak.map { pow(max(0, 1 - abs(x - $0) / 90), 1.6) * 1.8 } ?? 0
            return n(x) + pk + tilt * (x - Double(p.w) / 2) / amp
        }
        for x in 0..<p.w {
            let top = base - amp * f(Double(x)), ti = Int(top.rounded(.up))
            let shaded = f(Double(x) + 1) - f(Double(x)) < 0
            for y in min(p.h, max(0, ti - 2))..<p.h {
                let d = Double(y) - top
                if d < 0 {      // feathered crest: dithered partial coverage
                    if (2 + d) * 6 > bayer[y % 4][x % 4] { p.blend(x, y, mix(col, lit, 0.5), 0.6) }
                } else {
                    p.blend(x, y, shaded && d < 5 ? lit : col)
                }
            }
        }
    }

    // MARK: themes

    private static func build(_ t: ThemeID, _ seed: UInt64) -> Scene {
        var r = LCG(seed &+ UInt64(ThemeID.allCases.firstIndex(of: t)!) &* 7919)
        switch t {
        case .forest: return forest(&r)
        case .ocean: return sea(&r)
        case .sunset: return dusk(&r)
        case .night: return night(&r)
        case .random: return neutral(&r)   // never on screen (resolved first); kept for debug renders
        }
    }

    private static func forest(_ r: inout LCG) -> Scene {
        var back = Pix()
        dgrad(&back, y0: 0, y1: h, (34, 58, 62), (196, 206, 178), steps: 7)
        mountain(&back, &r, base: 74, amp: 14, (110, 138, 124), lit: (140, 164, 146), tilt: 0.12, peak: 90)   // far range
        mountain(&back, &r, base: 96, amp: 10, (78, 108, 92), lit: (96, 128, 108), tilt: -0.15, peak: 240)
        // Morning mist: soft alpha, seamless in x so it can drift forever. No dashes.
        var mist = Pix()
        let mp = (r.unit() * 6.28, r.unit() * 6.28)
        for y in 78..<106 { for x in 0..<w {
            let v = 1 - pow(abs(Double(y) - 92) / 14, 2)
            let fx = 2 * Double.pi * Double(x) / Double(w)
            let n = 0.65 + 0.2 * sin(fx * 2 + mp.0) + 0.15 * sin(fx * 5 + mp.1)
            mist.blend(x, y, (206, 214, 196), max(0, v) * n * 0.5)
        } }
        // Two crossing diagonal slopes; trees grow along each at varied heights.
        var trees = Pix()
        for (layer, (base, col, n, lo, hi)) in [(118.0, (52.0, 82.0, 64.0), 40, 14, 26), (150.0, (30.0, 52.0, 40.0), 26, 24, 40)].enumerated() {
            let k = layer == 0 ? -0.18 : 0.22
            func ground(_ x: Int) -> Int { Int(base + k * (Double(x) - Double(w) / 2) + 8 * sin(Double(x) / 37)) }
            for _ in 0..<n {
                let x = r.int(w + 20) - 10, th = lo + r.int(hi - lo + 1), gb = ground(x)
                for row in 0..<th {
                    let ww = Int(Double(row) * 0.32) + (row % 5 == 4 ? 1 : 0)
                    for xx in (x - ww)...(x + ww) {
                        trees.blend(xx, gb - th + row, Double(xx) < Double(x) + Double(ww) * 0.4 ? col : mix(col, (0, 0, 0), 0.15))
                    }
                }
            }
            for x in 0..<w { for y in min(h, max(0, ground(x)))..<h { trees.blend(x, y, col) } }
        }
        let leafSeed = r.unit()
        return Scene(layers: [Layer(image: back.image()), Layer(image: mist.image(), motion: .driftX(0.8)),
                              Layer(image: trees.image())],
                     sprites: { t in
                         // One or two leaves per ~30 s, falling slowly with a gentle sway.
                         (0..<2).compactMap { i -> Sprite? in
                             let period = 30.0, life = 20.0
                             let start = Double(i) * 13 + leafSeed * 10
                             let local = (t - start).truncatingRemainder(dividingBy: period)
                             guard t >= start, local < life else { return nil }
                             let cycle = floor((t - start) / period)
                             let x0 = 40 + (sin(cycle * 12.9898 + Double(i) * 78.233 + leafSeed * 100) * 0.5 + 0.5) * 240
                             let x = x0 + 10 * sin(local * 0.6)
                             let y = -4 + local / life * 160
                             return Sprite(rect: CGRect(x: x, y: y, width: 2, height: 1),
                                           color: Color(red: 0.78, green: 0.62, blue: 0.32))
                         }
                     })
    }

    private static func sea(_ r: inout LCG) -> Scene {
        var back = Pix()
        dgrad(&back, y0: 0, y1: 104, (26, 44, 78), (176, 202, 212), steps: 8)
        dgrad(&back, y0: 104, y1: h, (70, 130, 150), (18, 52, 76), steps: 6)
        for y in stride(from: 108, to: h, by: 4) {
            var x = r.int(11)
            while x < w {
                let len = 2 + r.int(5)
                for d in 0..<len { back.blend(x + d, y, (150, 196, 206), 0.6) }
                x += 10 + r.int(9)
            }
        }
        // Sun glitter: its own tall tile so it can flow slowly down the column (clip at horizon).
        let gh = h - 104
        var glitter = Pix(64, gh)
        for y in 0..<gh { for x in 0..<64 where r.unit() < 0.09 * (1 - abs(Double(x) - 32) / 32) {
            glitter.blend(x, y, (230, 232, 214))
        } }
        var clouds = Pix()
        for _ in 0..<5 {
            let cx = r.int(w), cy = 14 + r.int(56), cw = 24 + r.int(29)
            for k in 0..<3 { for x in (cx + k * 6)..<(cx + cw - k * 6) {
                clouds.blend(x % w, cy - k * 3, (214, 224, 230)); clouds.blend(x % w, cy - k * 3 + 1, (190, 206, 216))
            } }
        }
        // Cliff on the left, its face angling diagonally down into the sea.
        var cliff = Pix()
        func clifftop(_ x: Double) -> Double { 62 + x * 0.12 + 2 * sin(x / 9) }
        let edge = clifftop(70)
        for x in 0..<w {
            let fx = Double(x)
            let top = fx < 70 ? clifftop(fx) : edge + (fx - 70) * 1.6
            guard top < Double(h) else { break }
            let ti = Int(top.rounded(.up))
            if ti - 1 >= 0, bayer[(ti - 1) % 4][x % 4] < 8 { cliff.blend(x, ti - 1, (78, 92, 96), 0.5) }  // soft edge
            for y in ti..<h {
                cliff.blend(x, y, Double(y) - top < 3 ? (78, 92, 96) : mix((44, 54, 62), (24, 32, 42), Double(y) / Double(h)))
            }
        }
        let birdSeed = r.unit()
        return Scene(layers: [Layer(image: back.image()),
                              Layer(image: glitter.image(), origin: CGPoint(x: 198, y: 104), motion: .driftY(1.2, clipTop: 104)),
                              Layer(image: clouds.image(), motion: .driftX(1.0)),
                              Layer(image: cliff.image())],
                     sprites: { t in
                         // A seabird crosses about once a minute: fixed shape, steady speed.
                         let period = 55.0, start = 8 + birdSeed * 20
                         guard t >= start else { return [] }
                         let local = (t - start).truncatingRemainder(dividingBy: period), cycle = floor((t - start) / period)
                         let x = -6 + local * 9, y = 30 + (sin(cycle * 7.1 + birdSeed * 50) * 0.5 + 0.5) * 40
                         guard x < Double(w) + 6 else { return [] }
                         let c = Color(red: 0.16, green: 0.2, blue: 0.27)
                         return [Sprite(rect: CGRect(x: x, y: y, width: 2, height: 1), color: c),
                                 Sprite(rect: CGRect(x: x + 2, y: y + 1, width: 1, height: 1), color: c),
                                 Sprite(rect: CGRect(x: x + 3, y: y, width: 2, height: 1), color: c)]
                     })
    }

    /// v4: sky fills the frame; cumulus lit from below; two low slopes meet in a valley the sun sets into.
    private static func dusk(_ r: inout LCG) -> Scene {
        var sky = Pix()
        dgrad(&sky, y0: 0, y1: h, (52, 34, 74), (250, 170, 104), steps: 9)
        // Sun right of center, low: never under the timer ring.
        let sunR = 13.0
        var sun = Pix(28, 28)
        for y in 0..<28 { for x in 0..<28 where pow(Double(x) - 13.5, 2) + pow(Double(y) - 13.5, 2) <= sunR * sunR {
            sun.blend(x, y, (255, 218, 148))
        } }
        // Puffy cumulus: clumps of overlapping circles on a flat base, under-lit by the sun.
        var clouds = Pix()
        for _ in 0..<5 {
            let cx = Double(r.int(w)), base = 26 + Double(r.int(50)), width = 40 + Double(r.int(30))
            let puffs = (0..<(4 + r.int(3))).map { _ in (cx + r.unit() * width, 6 + r.unit() * 7) }
            for y in Int(base - 24)..<Int(base) { for xi in Int(cx - 14)..<Int(cx + width + 14) {
                let x = Double(xi), yy = Double(y)
                guard puffs.contains(where: { pow(x - $0.0, 2) + pow(yy - (base - $0.1 * 0.6), 2) <= $0.1 * $0.1 }) else { continue }
                let d = base - yy, wx = ((xi % w) + w) % w
                let lit = d < 2 || (d < 4 && bayer[y % 4][wx % 4] < 8)          // dithered warm underside
                let body = mix((150, 82, 112), (204, 110, 112), min(1, max(0, 1 - d / 18)))
                clouds.blend(wx, y, lit ? (255, 196, 150) : body)
            }}
        }
        // Two low diagonal slopes meeting in a valley at x≈200.
        var hills = Pix()
        let vx = 200.0
        for x in 0..<w {
            let fx = Double(x)
            let right = 160 - (fx - vx) * 0.28 + 1.5 * sin(fx / 11)
            let left = 124 + fx * 0.17 + 1.5 * sin(fx / 13)
            for y in 0..<h {
                let fy = Double(y)
                if fy >= right { hills.blend(x, y, (70, 42, 66)) }
                if fy >= left { hills.blend(x, y, (38, 26, 40)) }   // runs on under the right slope: no seam
                // soften crests
                if fy < right && fy >= right - 1 && bayer[y % 4][x % 4] < 8 { hills.blend(x, y, (70, 42, 66), 0.6) }
                if fy < left && fy >= left - 1 && fy >= right && bayer[y % 4][x % 4] < 8 { hills.blend(x, y, (38, 26, 40), 0.6) }
            }
        }
        return Scene(layers: [Layer(image: sky.image()),
                              Layer(image: sun.image(), origin: CGPoint(x: vx - 14, y: 126), motion: .sink(14, over: 180)),
                              Layer(image: clouds.image(), motion: .driftX(0.7)),
                              Layer(image: hills.image())],
                     sprites: { _ in [] })
    }

    private static func night(_ r: inout LCG) -> Scene {
        var sky = Pix()
        dgrad(&sky, y0: 0, y1: h, (10, 12, 34), (54, 58, 118), steps: 8)
        // Stars + Milky Way on an oversized square so slow rotation never shows its corners.
        let side = 500, pivot = CGPoint(x: 160, y: 180)
        var stars = Pix(side, side)
        let o = Double(side) / 2
        for _ in 0..<900 {
            let x = r.int(side), y = r.int(side)
            let b: RGB = [(160, 160, 210), (210, 210, 250), (255, 255, 255)][r.int(3)]
            stars.blend(x, y, b)
        }
        let tilt = r.unit() * 0.4 + 0.15
        for y in 0..<side { for x in 0..<side {
            let sx = Double(x) - o, sy = Double(y) - o
            let d = abs(sy + 70 - sx * tilt) / sqrt(1 + tilt * tilt)       // distance to band line
            if d < 14 && r.unit() < 0.14 * (1 - d / 14) { stars.blend(x, y, (180, 180, 230), 0.55) }
        } }
        var fg = Pix()
        let cx = 262.0, cy = 30.0
        for y in 20..<40 { for x in 252..<272 {
            let a = pow(Double(x) - cx, 2) + pow(Double(y) - cy, 2), b = pow(Double(x) - cx - 4, 2) + pow(Double(y) - cy + 2, 2)
            if a <= 81 && b > 64 { fg.blend(x, y, (236, 236, 248)) }
        } }
        mountain(&fg, &r, base: 130, amp: 10, (28, 30, 62), lit: (40, 44, 84), peak: 70)
        mountain(&fg, &r, base: 156, amp: 6, (14, 16, 36), lit: (20, 22, 48), tilt: 0.3)
        let meteorSeed = r.unit()
        return Scene(layers: [Layer(image: sky.image()),
                              Layer(image: stars.image(), origin: CGPoint(x: pivot.x - o, y: pivot.y - o),
                                    motion: .rotate(0.02, pivot: pivot)),      // ~3.6° over a 3-min break
                              Layer(image: fg.image())],
                     sprites: { t in
                         // Occasional meteor: a steady dot sliding across, constant brightness, no flash.
                         let period = 50.0, start = 15 + meteorSeed * 25, life = 4.0
                         guard t >= start else { return [] }
                         let local = (t - start).truncatingRemainder(dividingBy: period), cycle = floor((t - start) / period)
                         guard local < life else { return [] }
                         let x0 = 60 + (sin(cycle * 3.7 + meteorSeed * 90) * 0.5 + 0.5) * 180
                         let x = x0 + local * 18, y = 12 + local * 8
                         return [Sprite(rect: CGRect(x: x, y: y, width: 1, height: 1), color: Color(white: 0.92)),
                                 Sprite(rect: CGRect(x: x - 2, y: y - 1, width: 2, height: 1), color: Color(white: 0.6))]
                     })
    }

    private static func neutral(_ r: inout LCG) -> Scene { // graphite hills, works under any accent
        var sky = Pix()
        dgrad(&sky, y0: 0, y1: h, (44, 46, 52), (150, 154, 162), steps: 7)
        var clouds = Pix()
        for _ in 0..<4 {
            let cx = r.int(w), cy = 16 + r.int(40), cw = 24 + r.int(24)
            for k in 0..<2 { for x in (cx + k * 6)..<(cx + cw - k * 6) { clouds.blend(x % w, cy - k * 3, (196, 198, 204), 0.8) } }
        }
        var hills = Pix()
        mountain(&hills, &r, base: 104, amp: 12, (96, 99, 106), lit: (112, 115, 122), peak: 120)
        mountain(&hills, &r, base: 130, amp: 9, (64, 66, 72), lit: (76, 78, 84), tilt: 0.2)
        mountain(&hills, &r, base: 156, amp: 6, (38, 40, 45), lit: (46, 48, 53), tilt: -0.3)
        return Scene(layers: [Layer(image: sky.image()), Layer(image: clouds.image(), motion: .driftX(0.8)),
                              Layer(image: hills.image())], sprites: { _ in [] })
    }

    struct LCG {
        var s: UInt64
        init(_ seed: UInt64) { s = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
        mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000 }
    }
}

/// Full-bleed pixel scenery.
/// - dimmed: short-break background — darker and fully static.
/// - otherwise long break: slow translation only, ~15 fps, stopped by Reduce Motion.
struct SceneryView: View {
    let theme: ThemeID
    var seed: UInt64 = 1
    var dimmed = false
    var animate = true
    /// Fixed time for static review renders.
    var stillTime: Double = 0
    /// After dark: scenery at ~45% brightness instead of ~70%.
    var night = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let art = SceneryArt.load(theme, night: night) {
            artBody(art)
        } else {
            pixelBody
        }
    }

    /// Painted art (HANDOFF 2026-10-10). Base + layers share one canvas, aspect-fill, centered,
    /// overscaled 2% so a panning layer never exposes an edge on 16:10 or 16:9. Layer opacity is fixed.
    /// Only cloud/mist layers pan (long break, not under Reduce Motion). No full-screen scrim by day;
    /// after dark the whole scene is multiplied to ~65% (a dedicated -night.png is used as is).
    private func artBody(_ art: SceneryArt) -> some View {
        let still = dimmed || !animate || reduceMotion
        return ZStack {
            if still || !art.layers.contains(where: { $0.pans }) {
                artCanvas(art, t: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 15)) { ctx in
                    artCanvas(art, t: ctx.date.timeIntervalSince(art.born))
                }
            }
            if dimmed { Color.black.opacity(0.6) }
            else if night && !art.isNightArt { Color.black.opacity(SceneryArt.nightDim) }
            else if !night { Color.black.opacity(SceneryArt.dayDim) }
        }
        .ignoresSafeArea()
    }

    private func artCanvas(_ art: SceneryArt, t: Double) -> some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let iw = CGFloat(art.base.width), ih = CGFloat(art.base.height)
            let s: CGFloat = max(size.width / iw, size.height / ih) * SceneryArt.overscale
            let rect = CGRect(x: (size.width - iw * s) / 2, y: (size.height - ih * s) / 2, width: iw * s, height: ih * s)
            ctx.clip(to: Path(CGRect(origin: .zero, size: size)))
            ctx.draw(Image(decorative: art.base, scale: 1), in: rect)
            // Source px are in the 3840-wide design canvas, whatever size was decoded.
            let srcScale = rect.width / SceneryArt.designWidth
            for l in art.layers {
                var c = ctx
                c.opacity = l.opacity
                let dx = l.pans ? SceneryArt.panOffset(t) * srcScale : 0
                c.draw(Image(decorative: l.image, scale: 1), in: rect.offsetBy(dx: dx, dy: 0))
            }
        }
    }

    private var pixelBody: some View {
        let scene = Scenery.scene(theme, seed: seed)
        return ZStack {
            if dimmed || !animate || reduceMotion {
                canvas(scene, t: stillTime)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 15)) { ctx in
                    canvas(scene, t: ctx.date.timeIntervalSince(scene.born))
                }
            }
            Color.black.opacity(dimmed ? 0.6 : (night ? 0.55 : 0.3))
        }
        .ignoresSafeArea()
    }

    private func canvas(_ scene: Scenery.Scene, t: Double) -> some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let W = Double(Scenery.w), H = Double(Scenery.h)
            let s = max(size.width / W, size.height / H)
            ctx.translateBy(x: (size.width - W * s) / 2, y: (size.height - H * s) / 2)
            ctx.scaleBy(x: s, y: s)
            for layer in scene.layers {
                let img = ctx.resolve(Image(decorative: layer.image, scale: 1).interpolation(.none))
                let lw = Double(layer.image.width), lh = Double(layer.image.height)
                var o = layer.origin
                switch layer.motion {
                case .none:
                    ctx.draw(img, in: CGRect(origin: o, size: CGSize(width: lw, height: lh)))
                case .driftX(let v):
                    let dx = (v * t).truncatingRemainder(dividingBy: lw)
                    for k in [-1.0, 0] {
                        ctx.draw(img, in: CGRect(x: o.x + dx + k * lw, y: o.y, width: lw, height: lh))
                    }
                case .driftY(let v, let clipTop):
                    var c = ctx
                    c.clip(to: Path(CGRect(x: o.x, y: clipTop, width: lw, height: H - clipTop)))
                    let dy = (v * t).truncatingRemainder(dividingBy: lh)
                    for k in [-1.0, 0] {
                        c.draw(img, in: CGRect(x: o.x, y: o.y + dy + k * lh, width: lw, height: lh))
                    }
                case .sink(let n, let over):
                    o.y += n * min(1, t / over)
                    ctx.draw(img, in: CGRect(origin: o, size: CGSize(width: lw, height: lh)))
                case .rotate(let degPerSec, let p):
                    var c = ctx
                    c.translateBy(x: p.x, y: p.y)
                    c.rotate(by: .degrees(degPerSec * t))
                    c.translateBy(x: -p.x, y: -p.y)
                    c.draw(img, in: CGRect(origin: o, size: CGSize(width: lw, height: lh)))
                }
            }
            if t > 0 {
                for sp in scene.sprites(t) { ctx.fill(Path(sp.rect), with: .color(sp.color)) }
            }
        }
    }
}

/// Long-break art files. Looked up in order: $PAUSA_BACKGROUNDS, the app bundle's
/// Resources/backgrounds, then the repo's App/backgrounds (dev builds).
/// Names per HANDOFF: `<key>-base.png`, layers per `layerSpecs`, optional `<key>-night.png`.
/// Missing base → nil → the code-drawn pixel scenery is used.
struct SceneryArt {
    struct Layer { let image: CGImage; let opacity: Double; let pans: Bool }
    let base: CGImage
    let layers: [Layer]
    let isNightArt: Bool
    let born = Date()

    static let designWidth = 3840.0
    /// Slack of ≥36 source px per side even when width is the tight axis (16:9).
    static let overscale: CGFloat = 1.02
    /// After-dark multiply for the bright art: 65% brightness.
    static let nightDim = 0.35
    /// Daytime full-screen dim so white text sits on the art without a card (Steve option A).
    static let dayDim = 0.12
    /// Oil-paint look baked in once at load (generalized Kuwahara). Radius in px at 1920 wide,
    /// scaled with the decode size. Default: light.
    enum OilStrength: String, CaseIterable { case off, light, medium
        var radiusAt1920: Double { switch self { case .off: return 0; case .light: return 3; case .medium: return 6 } }
    }
    static var oilStrength: OilStrength = .light
    /// Clouds/mist: 0 → 24 source px over 120 s, then ease back the same way (cosine, no snap).
    static func panOffset(_ t: Double) -> Double { 12 * (1 - cos(2 * Double.pi * t / 240)) }

    static func key(_ t: ThemeID) -> String { t == .sunset ? "dusk" : t.rawValue }
    /// Fixed opacities from HANDOFF/manifest; never animated.
    static func layerSpecs(_ t: ThemeID) -> [(file: String, opacity: Double, pans: Bool)] {
        switch t {
        case .forest: return [("forest-layer", 0.25, true)]
        case .ocean: return [("ocean-layer", 0.60, true), ("ocean-glints-layer", 0.22, false)]
        case .sunset: return [("dusk-layer", 0.58, true)]
        case .night: return [("night-layer", 0.22, false)]
        case .random: return []
        }
    }

    /// HEIC first (smaller bundle), PNG as before. ImageIO decodes both.
    static let exts = ["heic", "png"]

    static var searchDirs: [URL] {
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["PAUSA_BACKGROUNDS"] { dirs.append(URL(fileURLWithPath: env)) }
        if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent("backgrounds")) }
        // Dev binaries (swift build / .build/.../debug) have no bundled art: walk up from the
        // executable to the checkout it was built in and use its App/backgrounds.
        var up = Bundle.main.executableURL?.deletingLastPathComponent()
        while let u = up, u.path != "/" {
            if u.lastPathComponent == ".build" {
                let repo = u.deletingLastPathComponent()
                dirs.append(repo.appendingPathComponent("App/backgrounds"))   // what release ships
                break
            }
            up = u.deletingLastPathComponent()
        }
        return dirs
    }

    /// Decode size: largest attached display in pixels (shared by all displays), capped at the art size.
    static var targetPixels: Int {
        let m = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 2880
        return Int(min(designWidth, max(1920, m.rounded(.up))))
    }

    private static var cache: [String: SceneryArt?] = [:]
    static var override: Int?   // debug renders force a decode size

    static func available(_ t: ThemeID) -> Bool {
        searchDirs.contains { d in exts.contains { FileManager.default.fileExists(atPath: d.appendingPathComponent("\(key(t))-base.\($0)").path) } }
    }

    /// One downsampled decode per theme/night/size; the previous one is dropped to keep memory sane.
    static func load(_ t: ThemeID, night: Bool) -> SceneryArt? {
        let px = override ?? targetPixels
        let k = "\(t.rawValue).\(night).\(px).\(oilStrength.rawValue)"
        if let hit = cache[k] { return hit }
        cache.removeAll()
        let art = find(t, night: night, px: px)
        cache[k] = art
        return art
    }

    private static func decode(_ url: URL, px: Int) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: px,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return painted(img) ?? img
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Generalized Kuwahara (Papari et al. style smooth weighting over 4 circular quadrants):
    /// each pixel takes the variance-weighted mean of its neighborhood quadrants, so flat areas
    /// become soft strokes while edges stay put. Runs on the GPU through Core Image.
    private static let kuwaharaKernel: CIKernel? = CIKernel(source: """
    kernel vec4 pausaKuwahara(sampler src, float radius) {
        vec2 dc = destCoord();
        int R = int(radius);
        float rr = radius * radius + 0.5;
        vec4 m0 = vec4(0.0); vec4 m1 = vec4(0.0); vec4 m2 = vec4(0.0); vec4 m3 = vec4(0.0);
        vec3 s0 = vec3(0.0); vec3 s1 = vec3(0.0); vec3 s2 = vec3(0.0); vec3 s3 = vec3(0.0);
        float n0 = 0.0; float n1 = 0.0; float n2 = 0.0; float n3 = 0.0;
        for (int j = -R; j <= R; j++) {
            for (int i = -R; i <= R; i++) {
                float fi = float(i); float fj = float(j);
                if (fi * fi + fj * fj <= rr) {
                    vec4 c = sample(src, samplerTransform(src, dc + vec2(fi, fj)));
                    vec3 c2 = c.rgb * c.rgb;
                    if (i <= 0 && j <= 0) { m0 += c; s0 += c2; n0 += 1.0; }
                    if (i >= 0 && j <= 0) { m1 += c; s1 += c2; n1 += 1.0; }
                    if (i <= 0 && j >= 0) { m2 += c; s2 += c2; n2 += 1.0; }
                    if (i >= 0 && j >= 0) { m3 += c; s3 += c2; n3 += 1.0; }
                }
            }
        }
        m0 /= n0; m1 /= n1; m2 /= n2; m3 /= n3;
        vec3 v0 = s0 / n0 - m0.rgb * m0.rgb; vec3 v1 = s1 / n1 - m1.rgb * m1.rgb;
        vec3 v2 = s2 / n2 - m2.rgb * m2.rgb; vec3 v3 = s3 / n3 - m3.rgb * m3.rgb;
        float e = 0.0004;
        float w0 = 1.0 / pow(e + abs(v0.r + v0.g + v0.b), 2.0);
        float w1 = 1.0 / pow(e + abs(v1.r + v1.g + v1.b), 2.0);
        float w2 = 1.0 / pow(e + abs(v2.r + v2.g + v2.b), 2.0);
        float w3 = 1.0 / pow(e + abs(v3.r + v3.g + v3.b), 2.0);
        return (m0 * w0 + m1 * w1 + m2 * w2 + m3 * w3) / (w0 + w1 + w2 + w3);
    }
    """)

    /// Last filter time in seconds (debug/timing).
    static var lastFilterSeconds: Double = 0

    /// Edges clamped before filtering and cropped back to the original extent: no fringe.
    static func painted(_ img: CGImage) -> CGImage? {
        let r = (oilStrength.radiusAt1920 * Double(max(img.width, img.height)) / 1920).rounded()
        guard r >= 1, let k = kuwaharaKernel else { return nil }
        let t0 = ProcessInfo.processInfo.systemUptime
        let ci = CIImage(cgImage: img)
        guard let out = k.apply(extent: ci.extent, roiCallback: { _, rect in rect.insetBy(dx: -r - 1, dy: -r - 1) },
                                arguments: [ci.clampedToExtent(), r]) else { return nil }
        let cg = ciContext.createCGImage(out.cropped(to: ci.extent), from: ci.extent, format: .RGBA8,
                                         colorSpace: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
        lastFilterSeconds = ProcessInfo.processInfo.systemUptime - t0
        #if DEBUG
        if ProcessInfo.processInfo.environment["PAUSA_OIL_TIMING"] != nil {
            FileHandle.standardError.write("oil r=\(Int(r)) \(img.width)x\(img.height) \(String(format: "%.0f", lastFilterSeconds * 1000)) ms\n".data(using: .utf8)!)
        }
        #endif
        return cg
    }

    private static func find(_ t: ThemeID, night: Bool, px: Int) -> SceneryArt? {
        let k = key(t)
        for dir in searchDirs {
            func img(_ name: String) -> CGImage? {
                for e in exts {
                    let u = dir.appendingPathComponent("\(name).\(e)")
                    if FileManager.default.fileExists(atPath: u.path) {
                        let cg = decode(u, px: px)
                        os.Logger(subsystem: "app.pausa", category: "scenery").info("background \(u.path, privacy: .public) \(cg == nil ? "FAILED" : "\(cg!.width)x\(cg!.height)", privacy: .public)")
                        return cg
                    }
                }
                return nil
            }
            guard let base = img("\(k)-base") else { continue }
            let layers = layerSpecs(t).compactMap { sp in img(sp.file).map { Layer(image: $0, opacity: sp.opacity, pans: sp.pans) } }
            if night, let n = img("\(k)-night") { return SceneryArt(base: n, layers: layers, isNightArt: true) }
            return SceneryArt(base: base, layers: layers, isNightArt: false)
        }
        return nil
    }
}
