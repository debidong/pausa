#if PAUSA_DEV
import AppKit
import SwiftUI

/// DEV builds only (`DEV=1 App/build-app.sh`). `Pausa --hero-mock <theme> [seconds]` opens one
/// ordinary 1024x640 borderless window (`<theme>` = scene, or a .png backdrop; `--bare` = no UI) with the real long-break view, frozen for the README hero:
/// English, 4:47, one fixed sentence, only the hold-to-skip capsule. No AppController is made, so the
/// scheduler, timers and break history are never touched; nothing covers the screen. Prints the
/// window number (for `screencapture -l`) and quits after `seconds` (default 8). See scripts/make-hero.sh.
/// Options: `--mock-daypart day|night|midnight` (default: day, or night for the night theme),
/// `--mock-lang <code>`, `--mock-quote <quote id>` (stderr reports the lines that quote needs).
enum HeroMock {
    static let sentence = "Look far. Then a little farther."
    static func handles(_ args: [String]) -> Bool { args.contains("--hero-mock") }

    @MainActor static func run(_ args: [String]) -> Never {
        AppLanguage.override = .en
        if args.contains("--about-mock") { about(args) }
        let i = args.firstIndex(of: "--hero-mock")!
        let what = i + 1 < args.count ? args[i + 1] : "ocean"
        func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if let l = opt("--mock-lang").flatMap(AppLanguage.init(rawValue:)) { AppLanguage.override = l }
        let quote = opt("--mock-quote").flatMap { RestQuotes.text(id: $0) } ?? sentence
        do { // Lines the quote needs at full size (scale-invariant: font = clock/3, width = clock*9).
            let cs = LongBreakView.clockSize(640), font = NSFont.systemFont(ofSize: cs / 3, weight: .semibold)
            let ts = NSTextStorage(string: quote, attributes: [.font: font]); let lm = NSLayoutManager()
            let tc = NSTextContainer(size: NSSize(width: cs * 9, height: 1e6)); tc.lineFragmentPadding = 0
            lm.addTextContainer(tc); ts.addLayoutManager(lm); lm.glyphRange(for: tc)
            var n = 0; lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { _, _, _, _, _ in n += 1 }
            FileHandle.standardError.write("mock-quote lines=\(n)\n".data(using: .utf8)!)
        }
        let backdrop = what.hasSuffix(".png") ? NSImage(contentsOfFile: what) : nil
        let theme = ThemeChoice(rawValue: what) ?? .ocean
        let daypart = opt("--mock-daypart").flatMap(BreakDaypart.init(rawValue:)) ?? (theme == .night ? .night : .day)
        let secs = (i + 2 < args.count ? Double(args[i + 2]) : nil) ?? 8
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let size = NSSize(width: 1024, height: 640)
        let vis = NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let w = KeyWindow(contentRect: NSRect(x: (vis.midX - size.width / 2).rounded(), y: (vis.midY - size.height / 2).rounded(),
                                             width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        let cd = Countdown(total: 300) {}   // never started
        let view = LongBreakView(countdown: cd, showControls: true, onSnooze: { _ in },
                                 theme: theme, seed: 1, animate: false, night: daypart != .day, daypart: daypart,
                                 fixedRemaining: 4 * 60 + 47, hold: HoldToSkip(), quote: quote,
                                 skipOnly: true, backdrop: backdrop, bare: args.contains("--bare"))
        // `--short`: the short break instead (scene behind, dim, live wipe over `seconds`).
        let short = args.contains("--short")
        let scd = Countdown(total: max(1, secs - 1)) {}
        let shortView = ZStack {
            LongBreakView(countdown: cd, showControls: false, onSnooze: { _ in }, theme: theme, seed: 1, animate: false,
                          night: daypart != .day, daypart: daypart, fixedRemaining: 0, hold: HoldToSkip(), quote: "",
                          skipOnly: true, backdrop: backdrop, bare: true)
            Color.black.opacity(BreakOverlayController.shortDim)
            ShortBreakCapsule(countdown: scd)
            VStack { Spacer(); ShortBreakControls(countdown: scd, hold: HoldToSkip()).padding(.bottom, 28) }
        }
        let host: NSView = short ? NSHostingView(rootView: shortView) : NSHostingView(rootView: view)
        if short { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { scd.start() } }
        host.frame = NSRect(origin: .zero, size: size)
        w.contentView = host
        // Active + key like the real break window: inactive windows draw Liquid Glass flat.
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        // activate() is asynchronous and can lose to the app that just quit; re-assert until key.
        for t in [0.3, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                if !w.isKeyWindow { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil) }
                FileHandle.standardError.write("hero-mock key=\(w.isKeyWindow) at \(t)s\n".data(using: .utf8)!)
            }
        }
        print(w.windowNumber); fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
        app.run()
        exit(0)
    }

    /// `--hero-mock --about-mock [--mock-lang <code>] [--mock-dark] [--mock-secs N]`: the real Settings window
    /// on the About tab; prints the window number, quits after N s.
    @MainActor private static func about(_ args: [String]) -> Never {
        func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if let l = opt("--mock-lang").flatMap(AppLanguage.init(rawValue:)) { AppLanguage.override = l }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AboutCard.glass = args.contains("--mock-glass")
        // The real Settings window (tabs, toolbar, size), on the About tab; its own frame key.
        let (w, tabs) = SettingsTabsController.makeWindow(settings: .shared, onPreview: {}, autosave: "PausaAboutMock")
        w.appearance = NSAppearance(named: args.contains("--mock-dark") ? .darkAqua : .aqua)
        tabs.select(.about)
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
        print(w.windowNumber); fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + (opt("--mock-secs").flatMap(Double.init) ?? 6)) { exit(0) }
        app.run(); exit(0)
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
}
#endif
