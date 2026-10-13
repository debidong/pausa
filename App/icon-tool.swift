// swift App/icon-tool.swift in.png out.png [size]
// Finds the rounded tile on a flat background (scans the centre row/column for the first pixel
// that differs from the corner colour), crops to it, masks it to a rounded rect and centres it on a
// transparent canvas with the macOS icon grid margin (824/1024).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
guard a.count >= 3, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("usage: in.png out.png [size]"); exit(1) }
let W = img.width, H = img.height
var px = [UInt8](repeating: 0, count: W * H * 4)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
px.withUnsafeMutableBytes { buf in
    let c = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
}
// Already an Apple-template icon (square, transparent corners): pass it through untouched.
let size0 = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 1024
if W == H, W == size0, px[3] == 0 {
    try? FileManager.default.removeItem(atPath: a[2])
    try! FileManager.default.copyItem(atPath: a[1], toPath: a[2])
    print("\(a[1]) \(W)x\(H) template icon -> \(a[2]) (unchanged)")
    exit(0)
}
func p(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * W + x) * 4; return (Int(px[i]), Int(px[i+1]), Int(px[i+2])) }
// Tile pixels are tinted (mint glass, cream paper); background and drop shadow are neutral grey.
// So a pixel belongs to the tile when its chroma (max-min channel) is clearly above the background's.
func chroma(_ x: Int, _ y: Int) -> Int { let q = p(x, y); return max(q.0, q.1, q.2) - min(q.0, q.1, q.2) }
let bgChroma = max(chroma(1, 1), chroma(W - 2, 1), chroma(1, H - 2), chroma(W - 2, H - 2))
func tinted(_ x: Int, _ y: Int) -> Bool { chroma(x, y) >= bgChroma + 6 }
/// First index whose pixel and the next two are tinted (ignores single noisy pixels).
func scan(_ r: StrideTo<Int>, _ f: (Int) -> Bool) -> Int {
    let a = Array(r)
    for k in 0..<max(0, a.count - 2) where f(a[k]) && f(a[k + 1]) && f(a[k + 2]) { return a[k] }
    return -1
}
let mx = W / 2, my = H / 2
// Take the median over a few rows/columns around the centre so one stray stroke can't move an edge.
func edge(_ lines: [Int], _ f: (Int) -> Int) -> Int { let v = lines.map(f).sorted(); return v[v.count / 2] }
let rows = [my - H / 8, my - H / 16, my, my + H / 16, my + H / 8]
let cols = [mx - W / 8, mx - W / 16, mx, mx + W / 16, mx + W / 8]
var l = edge(rows) { y in scan(stride(from: 0, to: mx, by: 1)) { tinted($0, y) } }
var r = edge(rows) { y in scan(stride(from: W - 1, to: mx, by: -1)) { tinted($0, y) } }
var t = edge(cols) { x in scan(stride(from: 0, to: my, by: 1)) { tinted(x, $0) } }
var b = edge(cols) { x in scan(stride(from: H - 1, to: my, by: -1)) { tinted(x, $0) } }
if l < 0 || r < 0 || t < 0 || b < 0 { l = 0; r = W - 1; t = 0; b = H - 1 }   // no background: use whole image
let inset = max(2, (r - l) / 100)                  // drop the edge shadow line
let tile = CGRect(x: l + inset, y: t + inset, width: r - l - 2 * inset, height: b - t - 2 * inset)
let size = a.count > 3 ? Int(a[3])! : 1024
let T = CGFloat(size) * 824 / 1024, o = (CGFloat(size) - T) / 2
let out = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
out.interpolationQuality = .high
let dst = CGRect(x: o, y: o, width: T, height: T)
out.addPath(CGPath(roundedRect: dst, cornerWidth: T * 0.2, cornerHeight: T * 0.2, transform: nil))
out.clip()
out.draw(img.cropping(to: tile)!, in: dst)   // cropping uses top-left origin, same as our scan
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("\(a[1]) \(W)x\(H) tile \(tile) -> \(a[2]) \(size)px")
