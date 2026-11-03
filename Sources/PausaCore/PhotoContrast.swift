import Foundation

/// 我的照片 contrast check (spec §3.5), done once at import: how much black to lay over the photo so
/// white text (clock, quote) keeps 4.5:1 on the brightest 5% of the text zone. Pure math on 8-bit
/// RGB(X) pixels; the app decodes and redraws the photo in sRGB first. Port of
/// pausa-photo-spec/assets/extra-dim.py, which is the reference (sample values in §3.5).
public enum PhotoContrast {
    /// Brightest background white text keeps 4.5:1 on: 1.05 / 4.5 - 0.05 = 0.18333.
    public static let maxBackgroundY = 1.05 / 4.5 - 0.05
    /// The same, as sRGB-encoded grey: g* = 0.4653.
    public static let maxBackgroundG = encode(maxBackgroundY)
    /// Upper bound for photoExtraDim. Pure white needs 0.535, so it only guards against bad input.
    public static let cap = 0.55
    /// The zone is shrunk to this long side (area average) before the percentile, for speed.
    public static let zoneMaxSide = 256

    /// sRGB component (0…1) to linear light.
    public static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    /// Linear light (0…1) to sRGB-encoded value.
    public static func encode(_ y: Double) -> Double { y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1 / 2.4) - 0.055 }
    /// Relative luminance (WCAG) of an 8-bit sRGB pixel.
    public static func luminance(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Double {
        0.2126 * linear(Double(r) / 255) + 0.7152 * linear(Double(g) / 255) + 0.0722 * linear(Double(b) / 255)
    }

    /// 95th percentile, nearest rank: the ceil(0.95 n)-th smallest. Empty input -> 0.
    public static func percentile95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s[max(0, Int((0.95 * Double(s.count)).rounded(.up)) - 1)]
    }

    /// Black layer opacity for an encoded grey g: a = g <= g* ? 0 : 1 - g*/g, rounded UP to 0.01,
    /// at most 0.55. (A 1e-9 slack keeps an exact hundredth from rounding up a step.)
    public static func extraDim(g: Double) -> Double {
        guard g > maxBackgroundG else { return 0 }
        return min(cap, ((1 - maxBackgroundG / g) * 100 - 1e-9).rounded(.up) / 100)
    }
    public static func extraDim(y95: Double) -> Double { extraDim(g: encode(y95)) }

    /// Integer pixel rect: the image cover-cropped (centred) to a screen of aspect w/h, then the
    /// middle 60% wide x 50% high of that crop. Edges rounded half-to-even, like the reference.
    public static func textZone(width w: Int, height h: Int, aspect: Double) -> (x: Int, y: Int, w: Int, h: Int) {
        let iw = Double(w), ih = Double(h)
        let cw = min(iw, ih * aspect), ch = min(ih, iw / aspect)
        let x0 = (iw - cw) / 2, y0 = (ih - ch) / 2
        let zx = x0 + cw * 0.2, zy = y0 + ch * 0.25
        func r(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }
        let x = r(zx), y = r(zy)
        return (x, y, max(1, r(zx + cw * 0.6) - x), max(1, r(zy + ch * 0.5) - y))
    }

    public struct Result: Equatable {
        public let y95: Double, g: Double, extraDim: Double
    }

    /// The whole §3.5 check. `pixels`: 8-bit RGB first in each pixel (RGBX / RGBA, alpha ignored),
    /// `bytesPerPixel` >= 3, rows `rowBytes` apart. `aspect`: the reference screen's width / height.
    public static func measure(pixels: [UInt8], width: Int, height: Int, bytesPerPixel: Int = 4,
                               rowBytes: Int? = nil, aspect: Double) -> Result {
        let rb = rowBytes ?? width * bytesPerPixel
        let z = textZone(width: width, height: height, aspect: aspect)
        // Crop the zone to a packed RGB plane.
        var rgb = [UInt8](repeating: 0, count: z.w * z.h * 3)
        for y in 0..<z.h {
            for x in 0..<z.w {
                let s = (z.y + y) * rb + (z.x + x) * bytesPerPixel, d = (y * z.w + x) * 3
                rgb[d] = pixels[s]; rgb[d + 1] = pixels[s + 1]; rgb[d + 2] = pixels[s + 2]
            }
        }
        var w = z.w, h = z.h
        let k = Double(zoneMaxSide) / Double(max(w, h))
        if k < 1 {
            let nw = max(1, Int((Double(w) * k).rounded(.toNearestOrEven)))
            let nh = max(1, Int((Double(h) * k).rounded(.toNearestOrEven)))
            rgb = boxResize(rgb, width: w, height: h, to: nw, nh); w = nw; h = nh
        }
        var ys = [Double](); ys.reserveCapacity(w * h)
        for i in 0..<(w * h) { ys.append(luminance(rgb[3 * i], rgb[3 * i + 1], rgb[3 * i + 2])) }
        let y95 = percentile95(ys), g = encode(y95)
        return Result(y95: y95, g: g, extraDim: extraDim(g: g))
    }

    /// Area-average shrink of a packed RGB plane, separable (rows, then columns) with each pass
    /// rounded to 8 bits, the way Pillow's BOX filter does it.
    static func boxResize(_ src: [UInt8], width w: Int, height h: Int, to nw: Int, _ nh: Int) -> [UInt8] {
        func weights(_ n: Int, _ m: Int) -> [(lo: Int, w: [Double])] {
            let scale = Double(n) / Double(m), support = scale * 0.5
            return (0..<m).map { i in
                let c = (Double(i) + 0.5) * scale
                let lo = max(0, Int(c - support + 0.5)), hi = min(n, Int(c + support + 0.5))
                var ws = (lo..<hi).map { j -> Double in
                    let t = (Double(j) - c + 0.5) / scale
                    return (t >= -0.5 && t < 0.5) ? 1 : 0
                }
                let sum = ws.reduce(0, +)
                if sum > 0 { ws = ws.map { $0 / sum } }
                return (lo, ws)
            }
        }
        func clamp(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        let wx = weights(w, nw), wy = weights(h, nh)
        var mid = [UInt8](repeating: 0, count: nw * h * 3)
        for y in 0..<h { for (x, c) in wx.enumerated() { for ch in 0..<3 {
            var acc = 0.0
            for (j, wt) in c.w.enumerated() { acc += wt * Double(src[(y * w + c.lo + j) * 3 + ch]) }
            mid[(y * nw + x) * 3 + ch] = clamp(acc)
        } } }
        var out = [UInt8](repeating: 0, count: nw * nh * 3)
        for (y, c) in wy.enumerated() { for x in 0..<nw { for ch in 0..<3 {
            var acc = 0.0
            for (j, wt) in c.w.enumerated() { acc += wt * Double(mid[((c.lo + j) * nw + x) * 3 + ch]) }
            out[(y * nw + x) * 3 + ch] = clamp(acc)
        } } }
        return out
    }
}
