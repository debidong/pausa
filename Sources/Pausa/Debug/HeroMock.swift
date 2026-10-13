#if PAUSA_DEV
import AppKit
import SwiftUI

/// DEV builds only (`DEV=1 App/build-app.sh`). `Pausa --hero-mock <theme> [seconds]` opens one
/// ordinary 1024x640 borderless window with the real long-break view, frozen for the README hero:
/// English, 4:47, one fixed sentence, only the hold-to-skip capsule. No AppController is made, so the
/// scheduler, timers and break history are never touched; nothing covers the screen. Prints the
/// window number (for `screencapture -l`) and quits after `seconds` (default 8). See scripts/make-hero.sh.
enum HeroMock {
    static let sentence = "Look far. Then a little farther."
    static func handles(_ args: [String]) -> Bool { args.contains("--hero-mock") }

    @MainActor static func run(_ args: [String]) -> Never {
        AppLanguage.override = .en
        let i = args.firstIndex(of: "--hero-mock")!
        let theme = (i + 1 < args.count ? ThemeChoice(rawValue: args[i + 1]) : nil) ?? .ocean
        let secs = (i + 2 < args.count ? Double(args[i + 2]) : nil) ?? 8
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let size = NSSize(width: 1024, height: 640)
        let vis = NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let w = KeyWindow(contentRect: NSRect(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2,
                                             width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        let cd = Countdown(total: 300) {}   // never started
        let view = LongBreakView(countdown: cd, showControls: true, onSnooze: { _ in },
                                 theme: theme, seed: 1, animate: false, night: theme == .night,
                                 fixedRemaining: 4 * 60 + 47, hold: HoldToSkip(), quote: sentence,
                                 skipOnly: true)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        w.contentView = host
        // Active + key like the real break window: inactive windows draw Liquid Glass flat.
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        print(w.windowNumber); fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
        app.run()
        exit(0)
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
}
#endif
