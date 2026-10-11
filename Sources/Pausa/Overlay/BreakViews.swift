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

/// v0.2 short break: a notification-like glass capsule at the top center of each screen.
/// No buttons, no numbers: a horizon glyph, one line of copy, and a hairline of progress.
struct ShortBreakCapsule: View {
    @ObservedObject var countdown: Countdown
    /// ImageRenderer cannot draw NSVisualEffectView; debug renders use a flat stand-in.
    var flatBackground = false
    var theme: ThemeID = .current
    /// × skips this short break.
    var onClose: () -> Void = {}
    /// Fades the card after ~2 s; hovering brings it back. Owned by the controller.
    @ObservedObject var fade = CardFade()

    private var cardOpacity: Double { fade.faded && !fade.hovering ? 0.06 : 1 }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "eye")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(theme.accent)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(BreakOverlayController.Copy.shortTitle)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                Text(BreakOverlayController.Copy.shortSubtitle(seconds: Int(countdown.total.rounded())))
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.96))     // ≥ 4.5:1 on the glass, see contrast notes
            }
            .fixedSize()
            Spacer(minLength: 8)
            Color.clear.frame(width: 30, height: 30)       // × lives in an overlay so it can stay visible
        }
        .padding(.leading, 18).padding(.trailing, 12)
        .padding(.top, 14).padding(.bottom, 18)
        .frame(width: 380)
        .fixedSize()
        .overlay(alignment: .bottom) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.22))
                    Capsule().fill(theme.accent).frame(width: g.size.width * min(1, max(0, countdown.progress)))
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 30).padding(.bottom, 6)
        }
        .modifier(CapsuleSurface(flat: flatBackground))
        .overlay(CardShape.shape.stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        .opacity(cardOpacity)
        .overlay(alignment: .trailing) {
            // Stays faintly visible in the same spot so the break can always be skipped.
            CloseButton(action: onClose)
                .padding(.trailing, 12)
                .opacity(max(cardOpacity, 0.3))
        }
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Theme.appLocale)
        .accessibilityElement(children: .combine)
        .padding(12) // room for the shadow
    }
}

final class CardFade: ObservableObject {
    @Published var faded = false
    @Published var hovering = false
}

/// Native glass button on macOS 26+, plain borderless before.
private struct CloseButton: View {
    let action: () -> Void
    var body: some View {
        let b = Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 18, height: 18)
        }
        .foregroundColor(.white.opacity(0.9))
        .help(BreakOverlayController.Copy.skipShort)
        .accessibilityLabel(BreakOverlayController.Copy.skipShort)
        if #available(macOS 26, *) {
            b.buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            b.buttonStyle(.borderless)
        }
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
    let onSnooze: () -> Void
    let onSkip: () -> Void
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
    /// Hold-Esc-to-skip progress (long break only); fills the Skip pill.
    var hold: HoldToSkip? = nil
    /// Debug renders only: draw the Skip fill at this progress.
    var debugHoldProgress: Double? = nil

    private var timeText: String {
        let s = Int((fixedRemaining ?? countdown.remaining).rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        ZStack {
            SceneryView(theme: theme, seed: seed, animate: animate, stillTime: stillTime, night: night)
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Text(timeText)
                        .font(.system(size: 76, weight: LongBreakView.countdownWeight).monospacedDigit())
                        .foregroundColor(.white)
                        .accessibilityLabel(timeText)
                        .padding(.bottom, 16)
                    Text(BreakOverlayController.Copy.long(minutes: max(1, Int((countdown.total / 60).rounded()))))
                        .font(.system(size: 34, weight: .medium))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                    Text(BreakOverlayController.Copy.longSubtitle)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.88))
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                }
                // Text on the art, no card: soft wide shadow + tight contact shadow.
                .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 2)
                .shadow(color: .black.opacity(0.30), radius: 1.5, x: 0, y: 1)
                .background(halo)
                if showControls {
                    HStack(spacing: 12) {
                        Button(BreakOverlayController.Copy.snooze, action: onSnooze)
                        Button(BreakOverlayController.Copy.skip, action: onSkip)
                            .overlay(SkipHoldFill(hold: hold ?? LongBreakView.idleHold, fixed: debugHoldProgress))
                    }
                    .buttonStyle(QuietButtonStyle())
                    .focusable(false) // stray Space/Return while typing must not snooze or skip
                    .padding(.top, 36)
                    Text(BreakOverlayController.Copy.holdEsc)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.white.opacity(0.7))
                        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 1)
                        .padding(.top, 12)
                }
            }
            .padding(40)
        }
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Theme.appLocale)
    }
}

extension LongBreakView {
    var hasArt: Bool { SceneryArt.available(theme) }
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

/// Skip pill fill, left to right, white 35%.
struct SkipHoldFill: View {
    @ObservedObject var hold: HoldToSkip
    var fixed: Double? = nil
    var body: some View {
        GeometryReader { g in
            Capsule().fill(Color.white.opacity(0.35))
                .frame(width: g.size.width * (fixed ?? hold.progress))
        }
        .clipShape(Capsule())
        .allowsHitTesting(false)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.22 : 0.12)))
    }
}

#if DEBUG
/// Offscreen render of the break views (no Screen Recording permission needed).
@MainActor
enum BreakViewSnapshots {
    static func write(to dir: URL) {
        for t in ThemeID.allCases {
            // Short break: ImageRenderer can't draw NSVisualEffectView, so a SwiftUI blur of a
            // stand-in "desktop" approximates the WindowServer frosted glass.
            let short = ImageRenderer(content: ZStack(alignment: .center) {
                SnapshotDesktop().blur(radius: 30).clipped()
                Color.black.opacity(BreakOverlayController.shortDim)
                ShortBreakCapsule(countdown: Countdown(total: 20, onDone: {}), flatBackground: true, theme: t)
            }.frame(width: 1440, height: 900))
            save(short.nsImage, dir.appendingPathComponent("\(t.rawValue)-short.png"))
            let long = ImageRenderer(content: LongBreakView(countdown: Countdown(total: 180, onDone: {}),
                                                            showControls: true, onSnooze: {}, onSkip: {},
                                                            theme: t, seed: 7, animate: false, stillTime: 60, night: false)
                .frame(width: 1440, height: 900))
            save(long.nsImage, dir.appendingPathComponent("\(t.rawValue)-long.png"))
            let longNight = ImageRenderer(content: LongBreakView(countdown: Countdown(total: 180, onDone: {}),
                                                                 showControls: true, onSnooze: {}, onSkip: {},
                                                                 theme: t, seed: 7, animate: false, stillTime: 60, night: true)
                .frame(width: 1440, height: 900))
            save(longNight.nsImage, dir.appendingPathComponent("\(t.rawValue)-long-night.png"))
        }
    }

    /// Long break per theme at 16:10 and 16:9 with a fixed 2:47 countdown.
    static func writeLong(to dir: URL, night: Bool = false) {
        SceneryArt.override = 1920
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for t in ThemeID.allCases {
            for (tag, w, h) in [("1610", 1920.0, 1200.0), ("169", 1920.0, 1080.0)] {
                let r = ImageRenderer(content: LongBreakView(countdown: Countdown(total: 180, onDone: {}),
                                                             showControls: true, onSnooze: {}, onSkip: {},
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
                                                         showControls: true, onSnooze: {}, onSkip: {},
                                                         theme: .forest, seed: 7, animate: false, stillTime: 60,
                                                         night: false, fixedRemaining: 167)
                .frame(width: 1920, height: 1200))
            r.scale = 1
            save(r.nsImage, dir.appendingPathComponent("long-forest-w-\(n).png"))
        }
        LongBreakView.countdownWeight = .semibold
        SceneryArt.override = nil
    }

    /// Writes just the short break (blur over a sample image) to `url`.
    static func writeShortBlur(to url: URL, sample: NSImage?) {
        let r = ImageRenderer(content: ZStack {
            Group {
                if let sample { Image(nsImage: sample).resizable().scaledToFill() } else { SnapshotDesktop() }
            }
            .frame(width: 1440, height: 900).blur(radius: 30, opaque: true).clipped()
            Color.black.opacity(BreakOverlayController.shortDim)
            ShortBreakCapsule(countdown: Countdown(total: 20, onDone: {}), flatBackground: true)
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
