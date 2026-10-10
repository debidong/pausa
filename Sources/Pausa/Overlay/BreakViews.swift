import SwiftUI
import AppKit

struct CountdownRing: View {
    @ObservedObject var countdown: Countdown
    var lineWidth: CGFloat
    var color: Color = Theme.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, 1 - countdown.progress))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 0.1), value: countdown.remaining)
        }
    }
}

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

struct ShortBreakCapsule: View {
    @ObservedObject var countdown: Countdown
    /// ImageRenderer cannot draw NSVisualEffectView; debug renders use a flat stand-in.
    var flatBackground = false

    var body: some View {
        HStack(spacing: 11) {
            CountdownRing(countdown: countdown, lineWidth: 2)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(BreakOverlayController.Copy.short)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                Text("\(Int(countdown.remaining.rounded(.up))) 秒")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .fixedSize()
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .padding(.vertical, 8)
        .background {
            if flatBackground {
                Capsule().fill(Color(white: 0.16).opacity(0.92))
            } else {
                VisualEffectBackground().clipShape(Capsule())
            }
        }
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .padding(10) // room for the shadow
    }
}

struct LongBreakView: View {
    @ObservedObject var countdown: Countdown
    let showControls: Bool
    let onSnooze: () -> Void
    let onSkip: () -> Void

    private var timeText: String {
        let s = Int(countdown.remaining.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                RadialGradient(colors: [Color(red: 0.09, green: 0.17, blue: 0.14),
                                        Color(red: 0.06, green: 0.08, blue: 0.08),
                                        Color(red: 0.03, green: 0.04, blue: 0.045)],
                               center: .center, startRadius: 0,
                               endRadius: max(geo.size.width, geo.size.height) * 0.7)
            }
            .opacity(0.96)
            .ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    CountdownRing(countdown: countdown, lineWidth: 3)
                    Text(timeText)
                        .font(.system(size: 22, weight: .regular).monospacedDigit())
                        .foregroundColor(.white.opacity(0.85))
                }
                .frame(width: 120, height: 120)
                .padding(.bottom, 36)

                Text(BreakOverlayController.Copy.long)
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(.white.opacity(0.92))
                Text(BreakOverlayController.Copy.longSubtitle)
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.top, 12)

                if showControls {
                    HStack(spacing: 14) {
                        Button(BreakOverlayController.Copy.snooze, action: onSnooze)
                        Button(BreakOverlayController.Copy.skip, action: onSkip)
                    }
                    .buttonStyle(QuietButtonStyle())
                    .focusable(false) // stray Space/Return while typing must not snooze or skip
                    .padding(.top, 40)
                }
            }
        }
        .environment(\.colorScheme, .dark)
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
        let short = ImageRenderer(content: ShortBreakCapsule(countdown: Countdown(total: 20, onDone: {}), flatBackground: true)
            .background(Color(white: 0.85)).environment(\.colorScheme, .dark))
        short.scale = 2
        save(short.nsImage, dir.appendingPathComponent("pausa-render-short.png"))
        let long = ImageRenderer(content: LongBreakView(countdown: Countdown(total: 180, onDone: {}),
                                                        showControls: true, onSnooze: {}, onSkip: {})
            .frame(width: 1440, height: 900))
        save(long.nsImage, dir.appendingPathComponent("pausa-render-long.png"))
    }

    private static func save(_ img: NSImage?, _ url: URL) {
        guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("render failed: \(url.lastPathComponent)"); return }
        try? png.write(to: url)
        print("wrote \(url.path)")
    }
}
#endif
