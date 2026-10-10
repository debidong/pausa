import SwiftUI
import AppKit

struct CountdownRing: View {
    @ObservedObject var countdown: Countdown
    var lineWidth: CGFloat
    var color: Color

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 1 - countdown.progress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: countdown.remaining)
        }
    }
}

struct ShortBreakCapsule: View {
    @ObservedObject var countdown: Countdown

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                CountdownRing(countdown: countdown, lineWidth: 2.5, color: .accentColor)
                Text("\(Int(countdown.remaining.rounded(.up)))")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .frame(width: 26, height: 26)
            Text(BreakOverlayController.Copy.short)
                .font(.system(size: 13, weight: .medium))
                .fixedSize()
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
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
            LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.16),
                                    Color(red: 0.05, green: 0.06, blue: 0.08)],
                           startPoint: .top, endPoint: .bottom)
                .opacity(0.94)
                .ignoresSafeArea()

            VStack(spacing: 36) {
                Text(BreakOverlayController.Copy.long)
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(.white.opacity(0.92))
                ZStack {
                    CountdownRing(countdown: countdown, lineWidth: 2, color: .white.opacity(0.85))
                    Text(timeText)
                        .font(.system(size: 22, weight: .regular).monospacedDigit())
                        .foregroundColor(.white.opacity(0.85))
                }
                .frame(width: 112, height: 112)

                if showControls {
                    HStack(spacing: 14) {
                        Button(BreakOverlayController.Copy.snooze, action: onSnooze)
                        Button(BreakOverlayController.Copy.skip, action: onSkip)
                    }
                    .buttonStyle(QuietButtonStyle())
                    .focusable(false) // stray Space/Return while typing must not snooze or skip
                    .padding(.top, 8)
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
        let short = ImageRenderer(content: ShortBreakCapsule(countdown: Countdown(total: 20, onDone: {}))
            .background(Color(white: 0.85)))
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
