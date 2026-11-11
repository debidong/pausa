import AppKit
import SwiftUI

/// Break UI. Short break = glass card centered on the screen under the mouse + a light click-through
/// dim on every screen; the user's app stays active. Long break = one window per screen at
/// .screenSaver level with countdown, quote, 「休息延后 5 分钟」「休息延后 15 分钟」. Hold Space to skip either.
///
/// All methods must be called on the main thread. Showing a new break replaces
/// any break currently on screen.
public final class BreakOverlayController {
    /// User-facing copy. Keys are stable; the Chinese text is the development-language default.
    public enum Copy {
        public static var shortTitle: String { L("break.short.hint") }
        /// 「休息延后 5 分钟」: postpone buttons in the popover and on the long-break screen.
        public static var ending: String { L("break.short.ending") }
        public static func snooze(_ minutes: Int) -> String { L("menu.postpone", minutes) }
        public static var holdToSkip: String { L("break.holdToSkip") }
        public static var spaceKey: String { L("key.space") }
    }

    /// Public presentation state of the break overlay, including the 5 s Settings preview.
    public enum Presentation: Equatable, Sendable {
        case hidden
        case shortBreak
        case longBreak(mustNotDefer: Bool)
        case preview

        public var isPresenting: Bool { self != .hidden }
    }

    public struct LongOptions: Equatable, Sendable {
        public var show15: Bool
        public var can15: Bool
        public var mustNotDefer: Bool
        public init(show15: Bool = true, can15: Bool = true, mustNotDefer: Bool = false) {
            self.show15 = show15
            self.can15 = can15
            self.mustNotDefer = mustNotDefer
        }
    }

    private enum Session {
        case hidden
        case short(onSkip: (() -> Void)?, onFinish: (() -> Void)?)
        case long(options: LongOptions,
                  onSnooze: (Int) -> Void,
                  onSkip: () -> Void,
                  onUrgent: (() -> Void)?,
                  onFinish: (() -> Void)?)
        case preview(onFinish: (() -> Void)?)

        var projection: Presentation {
            switch self {
            case .hidden: return .hidden
            case .short: return .shortBreak
            case .long(let opt, _, _, _, _): return .longBreak(mustNotDefer: opt.mustNotDefer)
            case .preview: return .preview
            }
        }
    }

    private var session: Session = .hidden {
        didSet { presentation = session.projection }
    }

    public private(set) var presentation: Presentation = .hidden
    /// Fired when an active overlay (short break, long break, or preview) returns to `.hidden`.
    public var onPresentationEnded: (() -> Void)?

    private let rendersWindows: Bool
    private var countdown: Countdown?
    private var dimWindows: [NSWindow] = []
    private var capsules: [NSPanel] = []
    /// Tint over the short-break blur; a bit stronger in Dark mode.
    static let shortDim = 0.25
    static let shortDimDark = 0.32
    static var currentShortDim: Double {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? shortDimDark : shortDim
    }
    /// 模糊桌面 (long break, both appearances): worst case is a white web page behind the blur;
    /// 0.55 keeps white text at 4.73:1 there. dayDim/nightDim are painting-only; midnightDim still applies.
    static let softDesktopDim = 0.55
    private var longWindows: [NSWindow] = []
    /// Hold Space to skip, both break types (round 3 §4). Shared by all break windows.
    private let holdToSkip = HoldToSkip()
    private var previousApp: NSRunningApplication?
    private var screenObserver: NSObjectProtocol?

    public init(rendersWindows: Bool = true) {
        self.rendersWindows = rendersWindows
        if rendersWindows {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.screensChanged() }
        }
    }

    deinit {
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// New per break so cloud/star positions and bird/meteor timing vary; shared across displays.
    private var sceneSeed: UInt64 = 1
    /// Picked once per break (kept across screen changes); see RestQuotes.
    private var longQuote: String?
    /// Daypart of the current long break, fixed when it starts (the screen style reads this).
    public private(set) var daypart: BreakDaypart = .current()
    #if PAUSA_DEV
    /// Dev link `&daypart=`: overrides the daypart of the next break only.
    public var devDaypartOverride: BreakDaypart?
    #endif
    /// Round 7c: while a break is up, Space reaching Pausa by ANY path (also with no key window, which
    /// is what made AppKit beep) goes through SpaceHold. Local monitor: no Accessibility permission.
    private var keyMonitor: Any?
    private func installKeyMonitor() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            guard let self, self.presentation.isPresenting else { return e }
            let hold: HoldToSkip? = {
                if case .longBreak(let locked) = self.presentation {
                    return Self.holdFor(mustNotDefer: locked, self.holdToSkip)
                }
                return self.holdToSkip
            }()
            return SpaceHold.handle(e, hold: hold, shownAt: self.shownAt) ? nil : e
        }
    }
    private func removeKeyMonitor() { if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil } }
    private var shownAt: TimeInterval = 0
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Fade-in for every break window (round 3b §1).
    static let fadeInDuration: TimeInterval = 0.5
    /// Fade-out mirrors it: 0.5 s, ease-in.
    static let fadeOutDuration: TimeInterval = 0.5

    // MARK: Short break

    /// Capsule near the cursor + slight dim. `onFinish` fires when time is up.
    public func showShort(duration: TimeInterval, onSkip: (() -> Void)? = nil, onFinish: (() -> Void)? = nil) {
        tearDownActiveOverlay(animated: false)
        session = .short(onSkip: onSkip, onFinish: onFinish)
        guard rendersWindows else { return }

        RandomScene.roll()
        PhotoBackground.prepare(long: false)
        let cd = Countdown(total: duration) { [weak self] in self?.finish() }
        countdown = cd

        sceneSeed = UInt64.random(in: 1...UInt64.max)
        holdToSkip.cancel(animated: false)
        holdToSkip.onComplete = { [weak self] in self?.skipShort() }
        dimWindows = NSScreen.screens.map(makeDimWindow)
        dimWindows.forEach { $0.alphaValue = 0 }
        // Card only on the screen under the mouse; other screens just dim.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        capsules = screen.map { [makeCapsule(countdown: cd, on: $0), makeShortControls(countdown: cd, on: $0)] } ?? []
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        fadeIn(dimWindows, short: true)
        capsules.forEach(appear)
        // Round 7b: key AFTER the fade has started (non-activating panel, so the user's app stays
        // active) and again on the next turn, so a late activation can't steal it back.
        takeKey(capsules.first)
        shownAt = ProcessInfo.processInfo.systemUptime; installKeyMonitor()
        cd.start()
    }

    // MARK: Long break & preview

    /// Full-screen break on every display. The user leaves via the postpone buttons, holding
    /// Space, or the countdown. `show15` / `can15`: round 3 §7.
    public func showLong(duration: TimeInterval,
                         onSnooze: @escaping (Int) -> Void,
                         onSkip: @escaping () -> Void,
                         onFinish: (() -> Void)? = nil,
                         show15: Bool = true, can15: Bool = true, mustNotDefer: Bool = false,
                         onUrgent: (() -> Void)? = nil) {
        tearDownActiveOverlay(animated: false)
        let options = LongOptions(show15: show15, can15: can15, mustNotDefer: mustNotDefer)
        session = .long(options: options,
                        onSnooze: onSnooze,
                        onSkip: onSkip,
                        onUrgent: mustNotDefer ? onUrgent : nil,
                        onFinish: onFinish)
        presentLongScene(duration: duration, options: options, hasUrgent: mustNotDefer && onUrgent != nil)
    }

    /// 5 s Settings preview of the long-break scene. Explicit `.preview` state blocks mid-preview Sparkle
    /// relaunches and suppresses pre-break panels without mutating `Scheduler`.
    public func showPreview(duration: TimeInterval = 5, onFinish: (() -> Void)? = nil) {
        tearDownActiveOverlay(animated: false)
        let options = LongOptions(show15: true, can15: true, mustNotDefer: false)
        session = .preview(onFinish: onFinish)
        presentLongScene(duration: duration, options: options, hasUrgent: false)
    }

    private func presentLongScene(duration: TimeInterval, options: LongOptions, hasUrgent: Bool) {
        guard rendersWindows else { return }
        RandomScene.roll()
        PhotoBackground.prepare(long: true)   // 我的照片…: decode now, or this break falls back to random
        let cd = Countdown(total: duration) { [weak self] in self?.finish() }
        countdown = cd

        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }

        sceneSeed = UInt64.random(in: 1...UInt64.max)
        daypart = .current()
        #if PAUSA_DEV
        if let d = devDaypartOverride { daypart = d; devDaypartOverride = nil }
        #endif
        longQuote = RestQuotes.next(daypart)
        holdToSkip.cancel(animated: false)
        holdToSkip.onComplete = { [weak self] in self?.skip() }
        buildLongWindows(options: options, hasUrgent: hasUrgent)
        longWindows.forEach { $0.alphaValue = 0 }   // no full-opacity frame before the fade-in
        fadeIn(longWindows, short: false)
        NSApp.activate(ignoringOtherApps: true)
        takeKey(longWindows.first { $0.screen == NSScreen.main } ?? longWindows.first)
        shownAt = ProcessInfo.processInfo.systemUptime; installKeyMonitor()
        cd.start()
    }

    /// Hide whatever is showing and return to `.hidden`. Does not invoke completion/skip callbacks.
    public func dismiss(animated: Bool = true) {
        guard presentation.isPresenting else { return }
        tearDownActiveOverlay(animated: animated)
        session = .hidden
        onPresentationEnded?()
    }

    private func tearDownActiveOverlay(animated: Bool) {
        guard presentation.isPresenting else { return }
        holdToSkip.cancel(animated: false)
        removeKeyMonitor()
        countdown?.stop(); countdown = nil
        let windows = dimWindows + longWindows + capsules
        dimWindows = []; longWindows = []; capsules = []
        if rendersWindows {
            fadeOut(windows, animated: animated)
            restorePreviousApp()   // short and long: key focus goes back to the app in front before the break
        }
    }

    // MARK: internals

    func completeCurrentSessionForTesting() { finish() }
    func skipCurrentSessionForTesting() {
        switch session {
        case .short: skipShort()
        case .long, .preview: skip()
        case .hidden: break
        }
    }

    private func finish() {
        let cb: (() -> Void)? = switch session {
        case .short(_, let f), .long(_, _, _, _, let f), .preview(let f): f
        case .hidden: nil
        }
        dismiss()
        cb?()
    }

    /// Space held: undim immediately, then let the scheduler start the next interval.
    private func skipShort() {
        holdToSkip.cancel(animated: false)
        guard case .short(let onSkip, _) = session else { return }
        dismiss(animated: false)
        onSkip?()
    }

    private func snooze(_ minutes: Int) {
        switch session {
        case .long(_, let onSnooze, _, _, _):
            dismiss()
            onSnooze(minutes)
        case .preview:
            dismiss()
        case .short, .hidden:
            break
        }
    }

    private func skip() {
        holdToSkip.cancel(animated: false)
        switch session {
        case .long(_, _, let onSkip, _, _):
            dismiss()
            onSkip()
        case .preview:
            dismiss()
        case .short, .hidden:
            break
        }
    }

    /// 「紧急暂停提醒」: off the screen at once, then the app pauses reminders.
    private func urgent() {
        guard case .long(_, _, _, let onUrgent?, _) = session else { return }
        dismiss(animated: false)
        onUrgent()
    }

    private func restorePreviousApp() {
        let app = previousApp
        previousApp = nil
        guard let app, !app.isTerminated else { return }
        app.activate(options: [])
    }

    private func screensChanged() {
        switch session {
        case .hidden:
            return
        case .short:
            dimWindows.forEach { $0.orderOut(nil) }
            dimWindows = NSScreen.screens.map(makeDimWindow)
            dimWindows.forEach { $0.alphaValue = 1; $0.orderFrontRegardless() }
            capsules.forEach { $0.orderOut(nil) }
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            if let cd = countdown, let screen {
                capsules = [makeCapsule(countdown: cd, on: screen), makeShortControls(countdown: cd, on: screen)]
                capsules.forEach { $0.alphaValue = 1; $0.orderFrontRegardless() }
            } else { capsules = [] }
        case .long(let options, _, _, let onUrgent, _):
            longWindows.forEach { $0.orderOut(nil) }
            buildLongWindows(options: options, hasUrgent: onUrgent != nil)
            longWindows.forEach { $0.alphaValue = 1; $0.orderFrontRegardless() }
        case .preview:
            longWindows.forEach { $0.orderOut(nil) }
            buildLongWindows(options: LongOptions(), hasUrgent: false)
            longWindows.forEach { $0.alphaValue = 1; $0.orderFrontRegardless() }
        }
    }

    private func buildLongWindows(options: LongOptions, hasUrgent: Bool) {
        guard let cd = countdown else { return }
        let mouse = NSEvent.mouseLocation
        let primary = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let tint = ThemeChoice.current == .softDesktop ? Self.softDesktopDim : Self.currentShortDim
        longWindows = NSScreen.screens.map { screen in
            let w = LongBreakWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.sharingType = .none
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.animationBehavior = .none
            w.hold = Self.holdFor(mustNotDefer: options.mustNotDefer, holdToSkip)
            let view = LongBreakView(countdown: cd, showControls: screen == primary,
                                     onSnooze: { [weak self] in self?.snooze($0) },
                                     seed: sceneSeed, daypart: daypart, hold: Self.holdFor(mustNotDefer: options.mustNotDefer, holdToSkip), quote: longQuote,
                                     show15: options.show15, can15: options.can15, locked: options.mustNotDefer,
                                     onUrgent: hasUrgent ? { [weak self] in self?.urgent() } : nil)
            // Same frosted layer underneath the scenery (shows through wherever the art is transparent).
            let frame = NSRect(origin: .zero, size: screen.frame.size)
            let base = Self.makeBlurView(frame: frame, tint: tint)
            let host = NSHostingView(rootView: view)
            host.frame = frame
            host.autoresizingMask = [.width, .height]
            base.addSubview(host)
            w.contentView = base
            w.alphaValue = 0
            return w
        }
    }

    /// Short-break backdrop: full-screen frosted glass of whatever is behind the window + light tint.
    /// Blending is done by WindowServer (.behindWindow); Pausa never reads screen pixels, so no
    /// Screen Recording permission. Completely static. Click-through, non-activating, never key.
    private func makeDimWindow(for screen: NSScreen) -> NSWindow {
        let w = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.sharingType = .none
        w.setFrame(screen.frame, display: false)
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.ignoresMouseEvents = true
        w.isOpaque = false
        w.hasShadow = false
        w.backgroundColor = .clear
        w.becomesKeyOnlyIfNeeded = true
        w.contentView = Self.makeBlurView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                          tint: Self.currentShortDim)
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.alphaValue = 0
        return w
    }

    /// NSVisualEffectView (behind-window, always active) with a flat black tint on top.
    static func makeBlurView(frame: NSRect, tint: Double) -> NSView {
        let blur = NSVisualEffectView(frame: frame)
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        let dim = NSView(frame: blur.bounds)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(tint).cgColor
        dim.autoresizingMask = [.width, .height]
        blur.addSubview(dim)
        return blur
    }

    /// Card in the middle of the visible frame, hint at the bottom: one transparent panel over the
    /// whole visible frame. Click-through; key (without activating Pausa) only to hear Space.
    private func makeCapsule(countdown: Countdown, on screen: NSScreen) -> NSPanel {
        let host = NSHostingView(rootView: ShortBreakCapsule(countdown: countdown, hold: holdToSkip))
        let vf = screen.frame   // full screen, same geometry as the long break (clock size/position match)
        let p = ShortBreakPanel(contentRect: vf, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.hold = holdToSkip
        p.level = .statusBar + 1
        p.sharingType = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        host.frame = NSRect(origin: .zero, size: vf.size)
        p.contentView = host
        p.alphaValue = 0
        return p
    }

    /// Short-break ring + skip capsule: a small clickable panel at the bottom center (40 pt up, same
    /// spot as the long-break controls) so the capsule takes a long-press; the content panel and the
    /// dim windows stay click-through. It hears Space too, in case a click makes it key.
    private func makeShortControls(countdown: Countdown, on screen: NSScreen) -> NSPanel {
        let host = NSHostingView(rootView: ShortBreakControls(countdown: countdown, hold: holdToSkip))
        let size = host.fittingSize
        let f = screen.frame
        let rect = NSRect(x: f.midX - size.width / 2, y: f.minY + 40 - 12, width: size.width, height: size.height)
        let p = ShortBreakPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.hold = holdToSkip
        p.level = .statusBar + 2
        p.sharingType = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        p.alphaValue = 0
        return p
    }

    /// Gentle appear: fade + scale 0.96→1 from the card's center; fade only under Reduce Motion.
    /// The panel never becomes key: keyboard stays with the user's app.
    private func appear(_ p: NSPanel) {
        p.alphaValue = 0
        p.orderFrontRegardless()
        if !reduceMotion, let v = p.contentView {
            v.wantsLayer = true
            if let layer = v.layer {
                let c = CGPoint(x: v.bounds.midX, y: v.bounds.midY)
                var t = CATransform3DMakeTranslation(c.x, c.y, 0)
                t = CATransform3DScale(t, 0.96, 0.96, 1)
                t = CATransform3DTranslate(t, -c.x, -c.y, 0)
                let a = CABasicAnimation(keyPath: "transform")
                a.fromValue = NSValue(caTransform3D: t)
                a.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                a.duration = Self.fadeInDuration
                a.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(a, forKey: "appear")
            }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeInDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }
    }

    private func fadeIn(_ windows: [NSWindow], short: Bool) {
        // Every break, short or long, manual (现在休息) or scheduled: 0.5 s opacity 0 → 1, ease-out,
        // the mirror of the fade-out. It is only a fade, so Reduce Motion keeps it.
        // Round 7 fix: the long break's first frame (blur + scenery) takes longer to draw than the
        // fade, so the fade used to finish before anything was on screen and the break popped in.
        // Order in at alpha 0, draw once, and start the fade on the next run-loop turn.
        windows.forEach { $0.alphaValue = 0; $0.orderFrontRegardless() }
        windows.forEach { w in w.contentView?.layoutSubtreeIfNeeded(); w.displayIfNeeded() }
        CATransaction.flush()
        let d = Self.fadeInDuration
        DispatchQueue.main.async {
            // A break dismissed before this turn (instant skip) must not fade back in.
            let live = windows.filter { $0.isVisible }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = d
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                live.forEach { $0.animator().alphaValue = 1 }
            }
        }
    }

    /// The break window takes the keyboard: now (after the fade started) and once more on the next
    /// run-loop turn, because NSApp.activate completes asynchronously on macOS 14+.
    private func takeKey(_ w: NSWindow?) {
        guard let w else { return }
        w.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak w] in
            guard let w, w.isVisible, !w.isKeyWindow else { return }
            w.makeKeyAndOrderFront(nil)
        }
    }

    private func fadeOut(_ windows: [NSWindow], animated: Bool) {
        let d = animated ? Self.fadeOutDuration : 0
        guard d > 0 else { windows.forEach { $0.orderOut(nil) }; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = d
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            windows.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            windows.forEach { $0.orderOut(nil) }
        })
    }
}

/// Hold Space 2 s to skip (round 7b). Releasing early resets to zero. Key repeats are swallowed (never
/// passed up, so no system beep while Space is held) and so is any Space pressed in
/// the first `grace` seconds, so a Space typed as the break appears never skips it. Return and
/// Enter are swallowed so they can't trigger a button.
enum SpaceHold {
    static let grace: TimeInterval = 0.5
    /// true = the event was consumed.
    static func handle(_ event: NSEvent, hold: HoldToSkip?, shownAt: TimeInterval) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp else { return false }
        switch event.keyCode {
        case 49: // Space
            if event.type == .keyDown {
                if !event.isARepeat && ProcessInfo.processInfo.systemUptime - shownAt >= grace { hold?.begin() }
            } else { hold?.cancel(animated: true) }
            return true
        case 36, 76: return true // Return, keypad Enter
        case _ where event.type == .keyDown && event.isARepeat: return true   // no beep on any held key
        default: return false
        }
    }
}

extension BreakOverlayController {
    /// nil past the hard line: Space is still swallowed by the window, but never skips.
    static func holdFor(mustNotDefer: Bool, _ hold: HoldToSkip) -> HoldToSkip? { mustNotDefer ? nil : hold }
    /// Debug self-test hook: the window that should be key while a break is up.
    var keyTargetForTest: NSWindow? { longWindows.first { $0.isKeyWindow } ?? capsules.first }
}

/// Long-break window: takes key so it hears Space.
final class LongBreakWindow: NSWindow {
    weak var hold: HoldToSkip?
    private let shownAt = ProcessInfo.processInfo.systemUptime
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if SpaceHold.handle(event, hold: hold, shownAt: shownAt) { return }
        super.sendEvent(event)
    }
    override func resignKey() { super.resignKey(); hold?.cancel(animated: true) }
    override func cancelOperation(_ sender: Any?) {}
}

/// Short-break panel: non-activating, but may become key so it hears Space while the user's app stays active.
final class ShortBreakPanel: NSPanel {
    weak var hold: HoldToSkip?
    private let shownAt = ProcessInfo.processInfo.systemUptime
    override var canBecomeKey: Bool { true }
    override var becomesKeyOnlyIfNeeded: Bool { get { false } set {} }
    override func sendEvent(_ event: NSEvent) {
        if SpaceHold.handle(event, hold: hold, shownAt: shownAt) { return }
        super.sendEvent(event)
    }
    override func resignKey() { super.resignKey(); hold?.cancel(animated: true) }
    override func cancelOperation(_ sender: Any?) {}
}

/// Progress of a held Space, 0…1. Reaching 1 calls `onComplete` once.
final class HoldToSkip: ObservableObject {
    static let duration: TimeInterval = 2.0
    @Published private(set) var progress: Double = 0
    var onComplete: (() -> Void)?
    private let clock: PausaClock
    private var startedAt: TimeInterval?
    private var timer: Timer?

    init(clock: PausaClock = .system) { self.clock = clock }

    func begin() {
        guard startedAt == nil else { return }
        startedAt = clock.uptimeNow()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let s = startedAt else { return }
        let p = min(1, (clock.uptimeNow() - s) / Self.duration)
        progress = p
        if p >= 1 { stop(); onComplete?() }
    }

    func cancel(animated: Bool) {
        stop()
        guard progress > 0 else { return }
        if animated { withAnimation(.easeOut(duration: 0.25)) { progress = 0 } } else { progress = 0 }
    }

    private func stop() { timer?.invalidate(); timer = nil; startedAt = nil }
}

/// Wall-clock-free countdown driven by a monotonic clock.
final class Countdown: ObservableObject {
    let total: TimeInterval
    @Published private(set) var remaining: TimeInterval
    private(set) var startedAt: TimeInterval = 0
    private let clock: PausaClock
    private var timer: Timer?
    private let onDone: () -> Void

    init(total: TimeInterval, clock: PausaClock = .system, onDone: @escaping () -> Void) {
        self.total = max(total, 0.1)
        self.remaining = total
        self.clock = clock
        self.onDone = onDone
    }

    var progress: Double { 1 - remaining / total }

    func start() {
        startedAt = clock.uptimeNow()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        remaining = max(0, total - (clock.uptimeNow() - startedAt))
        if remaining <= 0 { stop(); onDone() }
    }
}

