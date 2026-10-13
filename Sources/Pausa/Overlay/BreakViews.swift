import SwiftUI
import AppKit

/// Frosted glass that follows the system light/dark appearance.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Short break (glass proto): same language as the long break. No card: the prompt, its
/// description and a small glass countdown sit straight on the static blur; only controls are glass.
/// The controls live in their own clickable panel (ShortBreakControls) so this one stays click-through.
struct ShortBreakCapsule: View {
    @ObservedObject var countdown: Countdown
    /// ImageRenderer cannot draw glass / NSVisualEffectView; debug renders use flat stand-ins.
    var flatBackground = false
    var theme: ThemeID = .current
    var hold: HoldToSkip? = nil
    /// Hint index for this break (ShortHints): prompt `break.hint.N`, description `break.short.desc.N`.
    var hintIndex: Int = 0
    /// Debug renders only: pretend this many seconds are left.
    var fixedRemaining: Double? = nil

    static let clearFor: Double = 3
    static let fade: Double = 0.5

    private var remaining: Double { fixedRemaining ?? countdown.remaining }
    private var ending: Bool { remaining <= Self.clearFor }
    private var progress: Double { countdown.total > 0 ? max(0, min(1, 1 - remaining / countdown.total)) : 0 }

    var body: some View {
        VStack(spacing: 0) {
            Text(ShortHints.text(hintIndex))
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Text(ShortHints.desc(hintIndex))
                .font(.system(size: 17, weight: .regular))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .padding(.top, 10)
            VStack(spacing: 6) {
                Text(ending ? BreakOverlayController.Copy.ending : L("%d 秒", max(0, Int(remaining.rounded(.up)))))
                    .font(.system(size: 17, weight: .medium).monospacedDigit())
                    .foregroundColor(.white.opacity(0.9))
                    .fixedSize()
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule().fill(Color.white.opacity(0.85)).frame(width: 64 * progress)
                }
                .frame(width: 64, height: 2)
            }
            .padding(.horizontal, 18).padding(.vertical, 9)
            .modifier(ClearGlass(on: !flatBackground, shape: Capsule()))
            .padding(.top, 28)
        }
        .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Theme.appLocale)
        .accessibilityElement(children: .combine)
    }
}

/// Short-break controls: same glass row as the long break (postpone, then hold-Space-to-skip).
struct ShortBreakControls: View {
    var hold: HoldToSkip?
    var canPostpone = true
    var flat = false
    let onSnooze: (Int) -> Void
    var body: some View {
        HStack(spacing: 10) {
            if canPostpone { Button(BreakOverlayController.Copy.snooze(5)) { onSnooze(5) } }
            if let hold { HoldCapsule(hold: hold, glass: !flat) }
        }
        .buttonStyle(QuietButtonStyle(glass: !flat))
        .focusable(false)
        .modifier(GlassGroup(on: !flat))
        .padding(12)   // room for the glass edge
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Theme.appLocale)
    }
}

/// `.clear` Liquid Glass on macOS 26+; translucent fill below 26 / Reduce Transparency / renders.
struct ClearGlass<S: Shape>: ViewModifier {
    var on = true
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if on, !reduceTransparency, #available(macOS 26, *) {
            content.glassEffect(.clear, in: shape)
        } else {
            content.background(shape.fill(Color.white.opacity(reduceTransparency ? 0.22 : 0.12)))
        }
    }
}

/// 「按住空格键跳过」 as a glass capsule. Fills left to right while Space is held; retracts on release
/// (HoldToSkip.cancel animates progress back to 0). Not a button.
struct HoldCapsule: View {
    @ObservedObject var hold: HoldToSkip
    var fixed: Double? = nil
    var glass = true
    var body: some View {
        let p = max(0, min(1, fixed ?? hold.progress))
        Text(BreakOverlayController.Copy.holdSpace)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(alignment: .leading) {
                GeometryReader { g in
                    Rectangle().fill(Color.white.opacity(0.28)).frame(width: g.size.width * p)
                }
                .clipShape(Capsule())
            }
            .modifier(ClearGlass(on: glass, shape: Capsule()))
            .accessibilityElement(children: .combine)
    }
}

struct PieSlice: Shape {
    var progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    func path(in r: CGRect) -> Path {
        var p = Path()
        guard progress > 0 else { return p }
        let c = CGPoint(x: r.midX, y: r.midY)
        p.move(to: c)
        p.addArc(center: c, radius: r.width / 2, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(1, progress)), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// Card corners. macOS 26+: system concentric corners (ConcentricRectangle,
/// https://developer.apple.com/documentation/swiftui/concentricrectangle). A borderless panel
/// has no rounded container, so the documented `.concentric(minimum:)` floor is what resolves.
/// macOS 13–25: no public corner-radius token exists, so the same floor as a continuous rounded rect.
enum CardShape {
    static let minimumRadius: CGFloat = 16
    static var shape: AnyShape {
        if #available(macOS 26, *) {
            return AnyShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(minimumRadius)), isUniform: true))
        }
        return AnyShape(RoundedRectangle(cornerRadius: minimumRadius, style: .continuous))
    }
}

/// Liquid Glass on macOS 26+, frosted HUD material on 13-15, opaque when Reduce Transparency is on.
private struct CapsuleSurface: ViewModifier {
    let flat: Bool
    /// Dark tint so white text stays ≥ 4.5:1 even over a white wallpaper (measured, see PR notes).
    static let glassTint = 0.55
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if flat || reduceTransparency {
            content.background(CardShape.shape.fill(Color(white: 0.16).opacity(reduceTransparency ? 1 : 0.92)))
        } else if #available(macOS 26, *) {
            // Dark tint keeps the text legible over the dimmed screen.
            content.glassEffect(.regular.tint(Color.black.opacity(CapsuleSurface.glassTint)), in: CardShape.shape)
        } else {
            content.background(VisualEffectBackground().clipShape(CardShape.shape))
        }
    }
}

struct LongBreakView: View {
    @ObservedObject var countdown: Countdown
    let showControls: Bool
    /// Minutes: 5 or 15 (「休息延后 N 分钟」).
    let onSnooze: (Int) -> Void
    var theme: ThemeID = .current
    var seed: UInt64 = 1
    var animate = true
    var stillTime: Double = 0
    /// Darker scenery after dark; decided once when the break opens (no mid-break jumps).
    var night: Bool = Scenery.isNight()
    /// Debug renders only: show this many seconds instead of the live countdown.
    var fixedRemaining: Double? = nil
    /// Debug renders only: ImageRenderer can't draw glass/visual-effect, so use the flat fallback.
    var flatControls = false
    /// Hold-Space-to-skip progress.
    var hold: HoldToSkip? = nil
    /// Debug renders only: draw the ring at this progress.
    var debugHoldProgress: Double? = nil
    /// Rest quote under the countdown (RestQuotes), at most 3 lines.
    var quote: String? = nil
    /// Round 3 §7: 15 is hidden when the long-break allowance is under 15 min, dimmed when what's left is.
    var show15 = true
    var can15 = true
    /// Round 7b: past the 90-minute line. No skip hint and no postpone buttons, just the reason.
    var locked = false

    private var timeText: String {
        let s = Int((fixedRemaining ?? countdown.remaining).rounded(.up))
        return AppController.colonPair(s)
    }

    var body: some View {
        GeometryReader { g in content(clockSize: max(76, g.size.height * 0.12)) }
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Theme.appLocale)
    }

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Long-break clock. macOS 26: `.clear` Liquid Glass letters over a soft dark backing of the
    /// same digits (legibility on bright scenery). Earlier systems / renders / Reduce Transparency: white text.
    @ViewBuilder private func clock(size: CGFloat) -> some View {
        let digits = Text(timeText)
            .font(.system(size: size, weight: LongBreakView.countdownWeight).monospacedDigit())
        if !flatControls, !reduceTransparency, #available(macOS 26, *) {
            ZStack {
                digits.foregroundColor(.black.opacity(0.28)).blur(radius: size * 0.06)
                digits.foregroundColor(.white.opacity(0.18))
                    .overlay(Color.clear.glassEffect(.clear, in: Rectangle()).mask(digits))
            }
        } else {
            digits.foregroundColor(.white)
                .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 2)
                .shadow(color: .black.opacity(0.30), radius: 1.5, x: 0, y: 1)
        }
    }

    private func content(clockSize: CGFloat) -> some View {
        ZStack {
            SceneryView(theme: theme, seed: seed, animate: animate, stillTime: stillTime, night: night)
            VStack(spacing: 0) {
                clock(size: clockSize)
                    .accessibilityLabel(timeText)
                if let quote {
                    Text(quote)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.95))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 560)
                        .padding(.top, 14)
                        // Text on the art, no card: soft wide shadow + tight contact shadow.
                        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 2)
                        .shadow(color: .black.opacity(0.30), radius: 1.5, x: 0, y: 1)
                }
            }
            .background(halo)
            .padding(40)
            if showControls {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        if locked {
                            Text(L("已连续使用 90 分钟，长休息不能再推迟。"))
                                .font(.system(size: 13, weight: .medium)).foregroundColor(.white.opacity(0.85))
                        } else {
                            Button(BreakOverlayController.Copy.snooze(5)) { onSnooze(5) }
                            if show15 {
                                Button(BreakOverlayController.Copy.snooze(15)) { onSnooze(15) }.disabled(!can15)
                            }
                            HoldCapsule(hold: hold ?? LongBreakView.idleHold, fixed: debugHoldProgress, glass: !flatControls)
                        }
                    }
                    .buttonStyle(QuietButtonStyle(glass: !flatControls))
                    .focusable(false) // stray Space/Return while typing must not snooze or skip
                    .modifier(GlassGroup(on: !flatControls))
                    .padding(.bottom, 40)
                }
            }
        }
    }
}

extension LongBreakView {
    /// SF Pro Semibold digits; debug renders compare weights.
    static var countdownWeight: Font.Weight = .semibold
    static let idleHold = HoldToSkip()

    /// Per-theme faint local halo, only where the digits measured < 3:1 without it. 0 = none.
    static let haloPeak: [ThemeID: Double] = [:]

    @ViewBuilder var halo: some View {
        if let p = Self.haloPeak[theme], p > 0 {
            EllipticalGradient(colors: [.black.opacity(p), .black.opacity(p * 0.5), .black.opacity(0)], center: .center)
                .padding(-120)
                .allowsHitTesting(false)
        }
    }

}

struct QuietButtonStyle: ButtonStyle {
    /// Glass proto: `.clear` Liquid Glass capsules on macOS 26+ (inside one GlassEffectContainer).
    var glass = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .opacity(enabled ? 1 : 0.4)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 16).padding(.vertical, 7)
        if glass, !reduceTransparency, #available(macOS 26, *) {
            label.glassEffect(.clear.interactive(), in: Capsule())
        } else {
            label.background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.22 : 0.12)))
        }
    }
}

/// One GlassEffectContainer around the long-break controls on macOS 26+; no-op below.
struct GlassGroup: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on, #available(macOS 26, *) { GlassEffectContainer(spacing: 10) { content } } else { content }
    }
}

#if DEBUG
/// Offscreen render of the break views (no Screen Recording permission needed).
@MainActor
enum BreakViewSnapshots {
    static func write(to dir: URL) {
        for t in ThemeID.scenes {
            // Short break: ImageRenderer can't draw NSVisualEffectView, so a SwiftUI blur of a
            // stand-in "desktop" approximates the WindowServer frosted glass.
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
        // Countdown weight comparison (forest, 16:10).
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
        SceneryArt.override = nil
    }

    /// Quotes under the countdown: short (light / dark desktop) and long (forest day, night) per language.
    static func writeQuotes(to dir: URL, lang: String) {
        SceneryArt.override = 1920
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Longest quote in this language: worst case for wrapping.
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
        for t in [ThemeID.ocean] {   // brightest art: contrast check
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

    /// Writes just the short break (blur over a sample image) to `url`.
    static func writeShortBlur(to url: URL, sample: NSImage?, hint: Int = 0, opacity: Double = 1) {
        let r = ImageRenderer(content: ZStack {
            Group {
                if let sample { Image(nsImage: sample).resizable().scaledToFill() } else { SnapshotDesktop() }
            }
            .frame(width: 1440, height: 900).blur(radius: 30, opaque: true).clipped()
            Color.black.opacity(BreakOverlayController.shortDim)
            ShortBreakCapsule(countdown: Countdown(total: 20, onDone: {}), flatBackground: true,
                              hintIndex: hint, fixedRemaining: 19).opacity(opacity)
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
#endif
