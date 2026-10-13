#if DEBUG
import SwiftUI
import AppKit

/// PROTOTYPE (mitchell/glass-proto, not for merge): lock-screen-style break screens.
/// Liquid Glass on macOS 26+, NSVisualEffectView/material fallback on 13–15.
/// `--debug-render-glass <dir>` renders offscreen only: the hosting window is never ordered front.
enum GlassPath: String { case liquid, fallback }

/// Lock-screen clock: SF Pro, heavy-ish, slightly expanded width axis, tabular digits.
struct LockClockText: View {
    let text: String
    var size: CGFloat = 132
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold, design: .default).width(.expanded).monospacedDigit())
            .kerning(-2)
    }
}

/// A glass surface: real Liquid Glass when available, else the pre-26 material.
struct GlassSurface<S: Shape>: ViewModifier {
    let path: GlassPath
    let shape: S
    func body(content: Content) -> some View {
        if path == .liquid, #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 1))
        }
    }
}

struct GlassLongBreak: View {
    let path: GlassPath
    var night = false
    var time = "4:47"
    var quote = "Let your eyes rest on something far away."
    var body: some View {
        ZStack {
            // Current oil-painting scenery stays; glass sits on top of it.
            SceneryView(theme: .forest, animate: false, night: night)
            VStack(spacing: 6) {
                Text(Date(timeIntervalSince1970: 1_792_000_000), format: .dateTime.weekday(.wide).month().day())
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                LockClockText(text: time).foregroundStyle(.white.opacity(night ? 0.82 : 0.95))
                Text(quote).font(.system(size: 18, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                    .padding(.top, 8)
            }
            .shadow(color: .black.opacity(0.25), radius: 10, y: 2)
            .padding(.horizontal, 56).padding(.vertical, 32)
            .modifier(GlassSurface(path: path, shape: RoundedRectangle(cornerRadius: 40, style: .continuous)))
            .offset(y: -120)
            VStack { Spacer()
                HStack(spacing: 12) {
                    ForEach(["Hold Space to skip", "Snooze 5 min", "Snooze 15 min"], id: \.self) { s in
                        Text(s).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .modifier(GlassSurface(path: path, shape: Capsule()))
                    }
                }.padding(.bottom, 48)
            }
            if night { Color.black.opacity(0.25).allowsHitTesting(false) } // night dim over everything
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Short break: static background (no motion); the "look far away" line is the largest element.
struct GlassShortBreak: View {
    let path: GlassPath
    let dark: Bool
    var body: some View {
        ZStack {
            // Stand-in for the blurred, dimmed desktop (static).
            LinearGradient(colors: dark ? [Color(white: 0.12), Color(red: 0.1, green: 0.14, blue: 0.22)]
                                        : [Color(red: 0.75, green: 0.82, blue: 0.9), Color(white: 0.92)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 14) {
                Text("Look at something 6 m away")
                    .font(.system(size: 54, weight: .bold).width(.expanded))
                Text("0:17").font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(dark ? Color.white : Color.black.opacity(0.85))
            .padding(.horizontal, 60).padding(.vertical, 36)
            .modifier(GlassSurface(path: path, shape: RoundedRectangle(cornerRadius: 36, style: .continuous)))
        }
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

@MainActor
enum GlassProto {
    static func render<V: View>(_ v: V, dark: Bool, to url: URL, size: CGSize = CGSize(width: 1440, height: 900)) {
        let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        // Same config as the real break window, but never shown (no orderFront).
        let w = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.sharingType = .none
        w.level = .screenSaver
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.display()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path) visible=\(w.isVisible)")
    }

    static func renderAll(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if #available(macOS 26, *) { print("glassEffect available") } else { print("pre-26: liquid path falls back") }
        for p in [GlassPath.liquid, .fallback] {
            render(GlassLongBreak(path: p, night: false), dark: false, to: dir.appendingPathComponent("long-\(p.rawValue)-light.png"))
            render(GlassLongBreak(path: p, night: true), dark: true, to: dir.appendingPathComponent("long-\(p.rawValue)-dark.png"))
            render(GlassShortBreak(path: p, dark: false), dark: false, to: dir.appendingPathComponent("short-\(p.rawValue)-light.png"))
            render(GlassShortBreak(path: p, dark: true), dark: true, to: dir.appendingPathComponent("short-\(p.rawValue)-dark.png"))
        }
    }
}
#endif
