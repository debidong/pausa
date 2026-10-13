import SwiftUI
import AppKit
import PausaCore

// Pre-break reminder UI (SPEC-prebreak-v0.2 §2, §3). Display only: every number comes in through
// PreBreakState, computed by Scheduler (R7, R18). Nothing here counts time or allowance.

/// Everything the card and the cursor pill show. Built by the scheduler side once per tick.
struct PreBreakState: Equatable {
    struct DeferOption: Equatable {
        var minutes: Int
        /// false: shown dimmed (R5). An option that must not appear at all (R6: short +15,
        /// long +15 without `show15`) is simply left out of `deferOptions`.
        var enabled: Bool
    }
    var kind: BreakKind
    /// Seconds until the break starts.
    var secondsLeft: Int
    /// Length of the coming break, in seconds.
    var breakLength: Int
    /// `Scheduler.sinceLastLongBreak`, whole minutes (§4).
    var workedMinutes: Int
    /// In display order. Empty at the 90-minute line (R8).
    var deferOptions: [DeferOption]
    /// `Scheduler.postponeLeft`, whole minutes, rounded down (R7).
    var deferLeftMinutes: Int
    /// Short breaks only, never at the 90-minute line (R8, R9).
    var canSkip: Bool
    /// `Scheduler.atHardLine`: only 「现在休息」 plus the reason line.
    var atHardLine: Bool
    /// Any auto-pause reason or a manual pause (R14). Both windows close within this tick.
    var isAutoPaused: Bool
    /// `Scheduler.deferring == .typing`: the pill shows the waiting line, no number (§3).
    var typingWait: Bool = false
    /// Visibility is the scheduler's call (§2.1 lead/visible/re-show, §3 last 10 s, settings toggles).
    var showCard: Bool
    var showPill: Bool
}

/// Strings (Chinese source keys, translated in L10n.swift).
enum PreBreakCopy {
    static func title(_ k: BreakKind) -> String { k == .short ? L("马上休息一下") : L("长休息快到了") }
    static func length(_ k: BreakKind, seconds: Int) -> String {
        k == .short ? L("休息 %d 秒", seconds) : L("休息 %d 分钟", max(1, seconds / 60))
    }
    static func worked(_ m: Int) -> String { m < 1 ? L("刚休息过") : L("已连续工作 %d 分钟", m) }
    static var breakNow: String { L("现在休息") }
    static var skip: String { L("跳过这次") }
    static func plus(_ m: Int) -> String { L("推迟 %d 分钟", m) }
    static func deferLeft(_ m: Int) -> String { m > 0 ? L("还能推迟 %d 分钟", m) : L("推迟额度用完了") }
    static var hardLine: String { L("已连续使用 90 分钟，长休息不能再推迟。") }
    static func pill(_ s: Int) -> String { L("%d 秒后休息", s) }
    static var typing: String { L("写完这句再休息") }
    static var closeA11y: String { L("收起") }
}

/// Live model the panels observe, so each tick redraws without rebuilding the windows.
@MainActor
final class PreBreakModel: ObservableObject {
    @Published var state: PreBreakState
    init(_ s: PreBreakState) { state = s }
}

// MARK: - Views

/// Frosted material, or a flat stand-in for offscreen renders (visual effect views don't render offscreen).
private struct PreBreakSurface<S: Shape>: ViewModifier {
    let shape: S
    let flat: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        Group {
            if flat || reduceTransparency {
                content.background(shape.fill(scheme == .dark ? Color(white: 0.17) : Color(white: 0.965)))
            } else {
                content.background(VisualEffectBackground().clipShape(shape))
            }
        }
        .overlay(shape.stroke(Color.white.opacity(0.25), lineWidth: 0.5))
    }
}

private struct AppIconImage: View {
    let size: CGFloat
    var body: some View {
        Image(nsImage: NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
            .resizable().interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct PreBreakCard: View {
    @ObservedObject var model: PreBreakModel
    var flat = false
    var onPostpone: (Int) -> Void = { _ in }
    var onSkip: () -> Void = {}
    var onStartNow: () -> Void = {}
    var onClose: () -> Void = {}

    static let width: CGFloat = 360
    static let indent: CGFloat = 28          // icon 20 + gap 8: rows 2–5 line up with the title text
    static let gap: CGFloat = 6              // MenuPopoverView.buttonGap

    private var s: PreBreakState { model.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AppIconImage(size: 20)
                Text(PreBreakCopy.title(s.kind)).font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .accessibilityLabel(PreBreakCopy.closeA11y)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(AppController.clock(Double(s.secondsLeft)))
                    .font(.system(size: 28, weight: .semibold).monospacedDigit())
                (Text(PreBreakCopy.length(s.kind, seconds: s.breakLength)) + Text(" · ") + workedText)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                buttons.padding(.top, 10)
                if s.atHardLine {
                    Text(PreBreakCopy.hardLine).font(.system(size: 11)).foregroundColor(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                } else if !s.deferOptions.isEmpty {
                    Text(PreBreakCopy.deferLeft(s.deferLeftMinutes)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
            .padding(.leading, Self.indent)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: Self.width, alignment: .leading)
        .modifier(PreBreakSurface(shape: CardShape.shape, flat: flat))
    }

    /// Orange from 80 minutes on (§4).
    private var workedText: Text {
        let t = Text(PreBreakCopy.worked(s.workedMinutes))
        return s.workedMinutes >= 80 ? t.foregroundColor(Color(nsColor: .systemOrange)) : t
    }

    private var breakNow: some View {
        Button(PreBreakCopy.breakNow, action: onStartNow).buttonStyle(.borderedProminent).focusable(false)
    }

    /// R8: nothing but 「现在休息」 at the line. Otherwise postpone options (dimmed when over allowance), then skip.
    @ViewBuilder private var others: some View {
        if !s.atHardLine {
            ForEach(s.deferOptions, id: \.minutes) { o in
                Button(PreBreakCopy.plus(o.minutes)) { onPostpone(o.minutes) }
                    .buttonStyle(.bordered).disabled(!o.enabled || s.deferLeftMinutes <= 0).focusable(false)
            }
            if s.canSkip && s.kind == .short {
                Button(PreBreakCopy.skip, action: onSkip).buttonStyle(.bordered).focusable(false)
            }
        }
    }

    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Self.gap) { breakNow; others }
            VStack(alignment: .leading, spacing: Self.gap) { breakNow; HStack(spacing: Self.gap) { others } }
        }
        .controlSize(.small)
    }
}

struct CursorPill: View {
    @ObservedObject var model: PreBreakModel
    var flat = false
    var body: some View {
        HStack(spacing: 6) {
            AppIconImage(size: 14)
            Text(model.state.typingWait ? PreBreakCopy.typing : PreBreakCopy.pill(max(0, model.state.secondsLeft)))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .modifier(PreBreakSurface(shape: Capsule(), flat: flat))
    }
}

// MARK: - Windows

/// Non-activating, never key: clicks land, the frontmost app keeps the keyboard (R2).
private final class PreBreakPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the card and the pill. The scheduler side calls `update(_:)` every tick and wires the callbacks.
@MainActor
final class PreBreakController {
    var onPostpone: (Int) -> Void = { _ in }
    var onSkip: () -> Void = {}
    var onStartNow: () -> Void = {}
    /// The ✕ button. Changes no timing (R13); only hides the card until `showCard` next goes false → true.
    var onClose: () -> Void = {}

    private var model: PreBreakModel?
    private var card: PreBreakPanel?
    private var pill: PreBreakPanel?
    private var pillTimer: Timer?
    /// Card was dismissed by a button or ✕: stays hidden until the scheduler drops showCard.
    private var cardLatched = false

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// nil = nothing to show. Auto-pause hides both windows regardless of the show flags (R14).
    func update(_ s: PreBreakState?) {
        guard let s, !s.isAutoPaused else { hideCard(); hidePill(); cardLatched = false; return }
        if let model { if model.state != s { model.state = s } } else { model = PreBreakModel(s) }
        if !s.showCard { cardLatched = false }
        if s.showCard && !cardLatched { showCard() } else { hideCard() }
        if s.showPill { showPill() } else { hidePill() }
    }

    func dismissAll() { update(nil) }

    // Card

    private static func mouseScreen() -> NSScreen? {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main
    }

    private static func configure(_ p: NSPanel) {
        p.sharingType = .none                // never in a screen share or recording (R15)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
    }

    private func showCard() {
        guard card == nil, let model, let screen = Self.mouseScreen() else { return }
        let view = PreBreakCard(model: model,
                                onPostpone: { [weak self] m in self?.tap { $0.onPostpone(m) } },
                                onSkip: { [weak self] in self?.tap { $0.onSkip() } },
                                onStartNow: { [weak self] in self?.tap { $0.onStartNow() } },
                                onClose: { [weak self] in self?.tap { $0.onClose() } })
            .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 4)   // ShortBreakCapsule's shadow
            .padding(24)                                                    // room for the shadow
            .environment(\.locale, AppLanguage.current.locale)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let vf = screen.visibleFrame
        // Screen chosen once (D5); top centre, 12 pt under visibleFrame.maxY (shadow padding excluded).
        let frame = NSRect(x: vf.midX - size.width / 2, y: vf.maxY - 12 - size.height + 24,
                           width: size.width, height: size.height)
        let p = PreBreakPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        Self.configure(p)
        p.contentView = host
        p.alphaValue = 0
        let start = reduceMotion ? frame : frame.offsetBy(dx: 0, dy: 8)
        p.setFrame(start, display: false)
        p.orderFrontRegardless()
        card = p
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.3
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
            if start != frame { p.animator().setFrame(frame, display: true) }
        }
    }

    private func tap(_ f: (PreBreakController) -> Void) {
        cardLatched = true
        hideCard()
        f(self)
    }

    private func hideCard() {
        guard let p = card else { return }
        card = nil
        fadeOut(p)
    }

    private func fadeOut(_ p: NSPanel) {
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.25
            c.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }

    // Pill

    private func showPill() {
        guard pill == nil, let model else { return }
        let host = NSHostingView(rootView: CursorPill(model: model)
            .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 2).padding(10)
            .environment(\.locale, AppLanguage.current.locale))
        let p = PreBreakPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        Self.configure(p)
        p.ignoresMouseEvents = true          // clicks fall through to the app below (§3)
        p.contentView = host
        pill = p
        follow()
        p.orderFrontRegardless()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        RunLoop.main.add(t, forMode: .common)
        pillTimer = t
    }

    private func hidePill() {
        pillTimer?.invalidate(); pillTimer = nil
        guard let p = pill else { return }
        pill = nil
        fadeOut(p)
    }

    /// (+16, −20) from the pointer; flips left / above near an edge; always inside the pointer's screen.
    private func follow() {
        guard let p = pill, let host = p.contentView else { return }
        let size = host.fittingSize
        let m = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) else { return }
        p.setFrame(Self.pillFrame(mouse: m, size: size, in: screen.frame), display: true)
    }

    /// Pure geometry (size includes the 10 pt shadow margin). Exposed for the debug self-test.
    static func pillFrame(mouse m: NSPoint, size: NSSize, in sf: NSRect) -> NSRect {
        let inset: CGFloat = 10
        var x = m.x + 16 - inset
        var y = m.y - 20 - (size.height - inset)            // top of the pill 20 pt under the pointer
        if x + size.width > sf.maxX { x = m.x - 16 - size.width + inset }
        if y < sf.minY { y = m.y + 20 - inset }
        x = min(max(x, sf.minX), sf.maxX - size.width)
        y = min(max(y, sf.minY), sf.maxY - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

// MARK: - Offscreen renders (R17: no windows)

#if DEBUG
@MainActor
enum PreBreakSnapshots {
    static func sample(_ k: BreakKind, hardLine: Bool = false) -> PreBreakState {
        switch (k, hardLine) {
        case (.short, _):
            return PreBreakState(kind: .short, secondsLeft: 47, breakLength: 20, workedMinutes: 42,
                                 deferOptions: [.init(minutes: 1, enabled: true), .init(minutes: 5, enabled: false)],
                                 deferLeftMinutes: 1, canSkip: true, atHardLine: false, isAutoPaused: false,
                                 showCard: true, showPill: false)
        case (.long, false):
            return PreBreakState(kind: .long, secondsLeft: 58, breakLength: 300, workedMinutes: 83,
                                 deferOptions: [.init(minutes: 5, enabled: true), .init(minutes: 15, enabled: true)],
                                 deferLeftMinutes: 30, canSkip: false, atHardLine: false, isAutoPaused: false,
                                 showCard: true, showPill: false)
        case (.long, true):
            return PreBreakState(kind: .long, secondsLeft: 52, breakLength: 300, workedMinutes: 90,
                                 deferOptions: [], deferLeftMinutes: 0, canSkip: false, atHardLine: true,
                                 isAutoPaused: false, showCard: true, showPill: false)
        }
    }

    /// NSHostingView drawn into a bitmap without a window, so native buttons render too
    /// (ImageRenderer leaves AppKit-backed controls blank).
    static func png<V: View>(_ view: V, dark: Bool, to url: URL) {
        let host = NSHostingView(rootView: view.padding(16)
            .background(dark ? Color(white: 0.30) : Color(white: 0.80))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.locale, AppLanguage.current.locale))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("render failed: \(url.lastPathComponent)"); return }
        rep.size = host.bounds.size
        var out: NSBitmapImageRep = rep
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
            out = rep
        }
        guard let data = out.representation(using: .png, properties: [:]) else { print("render failed: \(url.lastPathComponent)"); return }
        try? data.write(to: url)
        print("wrote \(url.path)")
    }

    /// §2.5-13: short / long / 90-min line × light / dark × zh / en = 12 cards.
    /// §3-7: normal / typing × light / dark = 4 pills (per language).
    static func write(to dir: URL, cards: Bool = true, pills: Bool = true, langs: [AppLanguage] = [.zhHans, .en]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The unbundled debug binary has a generic icon; use the shipped one when run from the repo root.
        if let icon = NSImage(contentsOfFile: "App/AppIcon.icns") { NSApp.applicationIconImage = icon }
        let saved = AppLanguage.override
        defer { AppLanguage.override = saved }
        for lang in langs {
            AppLanguage.override = lang
            for (tag, st) in [("short", sample(.short)), ("long", sample(.long)), ("hardline", sample(.long, hardLine: true))] {
                for dark in [false, true] where cards {
                    png(PreBreakCard(model: PreBreakModel(st), flat: true), dark: dark,
                        to: dir.appendingPathComponent("card-\(tag)-\(lang.rawValue)-\(dark ? "dark" : "light").png"))
                }
            }
            for (tag, typing) in [("countdown", false), ("typing", true)] {
                var st = sample(.short); st.secondsLeft = 7; st.typingWait = typing
                for dark in [false, true] where pills {
                    png(CursorPill(model: PreBreakModel(st), flat: true), dark: dark,
                        to: dir.appendingPathComponent("pill-\(tag)-\(lang.rawValue)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    /// Window-free checks of the controller rules that don't need a screen.
    static func selftest() -> Bool {
        var ok = true
        func check(_ c: Bool, _ name: String) { print(c ? "ok   \(name)" : "FAIL \(name)"); ok = ok && c }
        let sf = NSRect(x: 0, y: 0, width: 1440, height: 900), size = NSSize(width: 140, height: 46)
        let mid = PreBreakController.pillFrame(mouse: NSPoint(x: 700, y: 450), size: size, in: sf)
        check(mid.minX == 706 && mid.maxY == 440, "pill sits at (+16, −20) from the pointer")
        let corner = PreBreakController.pillFrame(mouse: NSPoint(x: 1435, y: 3), size: size, in: sf)
        check(sf.contains(corner) && corner.maxX <= 1435 && corner.minY >= 3, "pill flips left and up in the bottom-right corner")
        let second = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        check(second.contains(PreBreakController.pillFrame(mouse: NSPoint(x: 1441, y: 1079), size: size, in: second)),
              "pill stays inside the pointer's screen")
        // Content rules, read off the view's inputs.
        let short = sample(.short), long = sample(.long), hard = sample(.long, hardLine: true)
        check(!short.deferOptions.contains { $0.minutes == 15 }, "short sample offers no +15 (R6)")
        check(hard.deferOptions.isEmpty && !hard.canSkip, "hard line: no postpone, no skip (R8)")
        check(!long.canSkip, "long: no skip (R9)")
        return ok
    }
}
#endif
