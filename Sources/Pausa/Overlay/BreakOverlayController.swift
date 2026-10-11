import AppKit
import SwiftUI

/// Break UI. Short break = glass card centered on the screen under the mouse + a light click-through
/// dim on every screen; never takes focus. Long break = one window per screen
/// at .screenSaver level with copy, countdown ring, 「推迟 5 分钟」「跳过」.
///
/// All methods must be called on the main thread. Showing a new break replaces
/// any break currently on screen.
public final class BreakOverlayController {
    /// User-facing copy. Keys are stable; the Chinese text is the development-language default.
    public enum Copy {
        public static var shortTitle: String { L("break.short.title") }
        public static func shortSubtitle(seconds: Int) -> String {
            L("break.short.subtitle", seconds)
        }
        public static func long(minutes: Int) -> String {
            L("break.long.title", minutes)
        }
        public static var longSubtitle: String { L("break.long.subtitle") }
        public static var snooze: String { L("break.long.snooze") }
        public static var skip: String { L("break.long.skip") }
        public static var holdEsc: String { L("break.long.holdEsc") }
        public static var skipShort: String { L("break.short.skip") }
    }

    private enum Mode {
        case short
        case long(onSnooze: () -> Void, onSkip: () -> Void)
    }

    private var mode: Mode?
    private var countdown: Countdown?
    private var onFinish: (() -> Void)?
    private var dimWindows: [NSWindow] = []
    private var capsules: [NSPanel] = []
    private var onShortSkip: (() -> Void)?
    /// Tint over the short-break blur; a bit stronger in Dark mode.
    static let shortDim = 0.25
    static let shortDimDark = 0.32
    static var currentShortDim: Double {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? shortDimDark : shortDim
    }
    private var longWindows: [NSWindow] = []
    /// Long break only: hold Esc 1 s to skip. Shared by all long-break windows.
    private let holdToSkip = HoldToSkip()
    private var previousApp: NSRunningApplication?
    private var screenObserver: NSObjectProtocol?
    private var keyMonitor: Any?

    public var isShowing: Bool { mode != nil }

    public init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged() }
    }

    deinit {
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// New per break so cloud/star positions and bird/meteor timing vary; shared across displays.
    private var sceneSeed: UInt64 = 1
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var fadeDuration: TimeInterval { reduceMotion ? 0 : 1.0 }

    // MARK: Short break

    /// Capsule near the cursor + slight dim. `onFinish` fires when time is up.
    public func showShort(duration: TimeInterval, onSkip: (() -> Void)? = nil, onFinish: (() -> Void)? = nil) {
        dismiss(animated: false)
        mode = .short
        self.onFinish = onFinish
        self.onShortSkip = onSkip
        let cd = Countdown(total: duration) { [weak self] in self?.finish() }
        countdown = cd

        sceneSeed = UInt64.random(in: 1...UInt64.max)
        dimWindows = NSScreen.screens.map(makeDimWindow)
        // Card only on the screen under the mouse; other screens just dim.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        capsules = screen.map { [makeCapsule(countdown: cd, on: $0)] } ?? []
        fadeIn(dimWindows, short: true)
        capsules.forEach(appear)
        cd.start()
    }

    // MARK: Long break

    /// Full-screen break on every display. Escape does nothing on purpose; the
    /// user leaves via the buttons or the countdown.
    public func showLong(duration: TimeInterval,
                         onSnooze: @escaping () -> Void,
                         onSkip: @escaping () -> Void,
                         onFinish: (() -> Void)? = nil) {
        dismiss(animated: false)
        mode = .long(onSnooze: onSnooze, onSkip: onSkip)
        self.onFinish = onFinish
        let cd = Countdown(total: duration) { [weak self] in self?.finish() }
        countdown = cd

        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }

        sceneSeed = UInt64.random(in: 1...UInt64.max)
        holdToSkip.cancel(animated: false)
        holdToSkip.onComplete = { [weak self] in self?.skip() }
        buildLongWindows()
        NSApp.activate(ignoringOtherApps: true)
        longWindows.first { $0.screen == NSScreen.main }?.makeKeyAndOrderFront(nil)
        fadeIn(longWindows, short: false)
        cd.start()
    }

    /// Hide whatever is showing. Does not call any callback.
    public func dismiss(animated: Bool = true) {
        guard mode != nil else { return }
        let wasLong: Bool = { if case .long = mode { return true }; return false }()
        countdown?.stop(); countdown = nil
        mode = nil
        onFinish = nil
        onShortSkip = nil
        let windows = dimWindows + longWindows + capsules
        dimWindows = []; longWindows = []; capsules = []
        fadeOut(windows, animated: animated)
        if wasLong { restorePreviousApp() }
    }

    // MARK: internals

    private func finish() {
        let cb = onFinish
        dismiss()
        cb?()
    }

    /// × on the capsule: undim immediately, then let the scheduler start the next interval.
    private func skipShort() {
        guard case .short = mode else { return }
        let cb = onShortSkip
        dismiss(animated: false)
        cb?()
    }

    private func snooze() {
        guard case .long(let onSnooze, _) = mode else { return }
        dismiss(); onSnooze()
    }

    private func skip() {
        holdToSkip.cancel(animated: false)
        guard case .long(_, let onSkip) = mode else { return }
        dismiss(); onSkip()
    }

    private func restorePreviousApp() {
        let app = previousApp
        previousApp = nil
        guard let app, !app.isTerminated else { return }
        app.activate(options: [])
    }

    private func screensChanged() {
        guard let mode else { return }
        switch mode {
        case .short:
            dimWindows.forEach { $0.orderOut(nil) }
            dimWindows = NSScreen.screens.map(makeDimWindow)
            dimWindows.forEach { $0.alphaValue = 1; $0.orderFrontRegardless() }
            capsules.forEach { $0.orderOut(nil) }
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            if let cd = countdown, let screen {
                capsules = [makeCapsule(countdown: cd, on: screen)]
                capsules.forEach { $0.alphaValue = 1; $0.orderFrontRegardless() }
            } else { capsules = [] }
        case .long:
            longWindows.forEach { $0.orderOut(nil) }
            buildLongWindows()
            longWindows.forEach { $0.alphaValue = 1; $0.orderFrontRegardless() }
        }
    }

    private func buildLongWindows() {
        guard let cd = countdown else { return }
        let mouse = NSEvent.mouseLocation
        let primary = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        longWindows = NSScreen.screens.map { screen in
            let w = LongBreakWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.animationBehavior = .none
            w.hold = holdToSkip
            let view = LongBreakView(countdown: cd, showControls: screen == primary,
                                     onSnooze: { [weak self] in self?.snooze() },
                                     onSkip: { [weak self] in self?.skip() },
                                     seed: sceneSeed, hold: holdToSkip)
            // Same frosted layer underneath the scenery (shows through wherever the art is transparent).
            let frame = NSRect(origin: .zero, size: screen.frame.size)
            let base = Self.makeBlurView(frame: frame, tint: Self.currentShortDim)
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

    /// Top center, just under the menu bar (and therefore clear of the notch).
    private func makeCapsule(countdown: Countdown, on screen: NSScreen) -> NSPanel {
        let fade = CardFade()
        let host = FirstMouseHostingView(rootView: ShortBreakCapsule(countdown: countdown,
                                                                     onClose: { [weak self] in self?.skipShort() },
                                                                     fade: fade))
        let rm = reduceMotion
        let anim: Animation? = rm ? nil : .easeInOut(duration: 0.6)
        host.onHover = { inside in withAnimation(anim) { fade.hovering = inside } }
        // Show ~2 s, then get out of the way (the dim stays).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation(rm ? nil : .easeInOut(duration: 1.2)) { fade.faded = true } }
        let size = host.fittingSize
        let vf = screen.visibleFrame                                      // centered, clear of menu bar/Dock/notch
        let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2)

        let p = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar + 1
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = false   // × is clickable; dim windows stay click-through
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.contentView = host
        p.alphaValue = 0
        return p
    }

    /// Gentle appear: fade + scale 0.96→1 from the card's center; fade only under Reduce Motion.
    /// The panel never becomes key: keyboard stays with the user's app.
    private func appear(_ p: NSPanel) {
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
                a.duration = 0.35
                a.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(a, forKey: "appear")
            }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.2 : 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }
    }

    private func fadeIn(_ windows: [NSWindow], short: Bool) {
        windows.forEach { $0.orderFrontRegardless() }
        // Short break: always a plain 0.35 s fade (it is only a fade, so Reduce Motion keeps it).
        let d = short ? 0.35 : fadeDuration
        guard d > 0 else { windows.forEach { $0.alphaValue = 1 }; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = d
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            windows.forEach { $0.animator().alphaValue = 1 }
        }
    }

    private func fadeOut(_ windows: [NSWindow], animated: Bool) {
        let d = animated ? fadeDuration : 0
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

/// Clicks land on the first try in a non-activating panel, without activating Pausa.
/// Hover is tracked with `.activeAlways` so it works while another app stays active (no focus change).
final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    var onHover: ((Bool) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.userInfo?["pausa"] != nil }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["pausa": true]))
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onHover?(true) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onHover?(false) }
}

/// Borderless window that can take key so buttons respond on first click.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Long-break window: takes key so it can see Esc. Tapping Esc does nothing; holding it 1.0 s
/// skips (key repeats ignored, timing from keyDown/keyUp). Return/Space are swallowed so they can
/// never trigger Snooze/Skip.
final class LongBreakWindow: NSWindow {
    weak var hold: HoldToSkip?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown || event.type == .keyUp {
            switch event.keyCode {
            case 53: // Esc
                if event.type == .keyDown { if !event.isARepeat { hold?.begin() } }
                else { hold?.cancel(animated: true) }
                return
            case 36, 76, 49: return // Return, keypad Enter, Space
            default: break
            }
        }
        super.sendEvent(event)
    }
    override func resignKey() { super.resignKey(); hold?.cancel(animated: true) }
    override func cancelOperation(_ sender: Any?) {}
}

/// Progress of a held Esc, 0…1. Reaching 1 calls `onComplete` once.
final class HoldToSkip: ObservableObject {
    static let duration: TimeInterval = 1.0
    @Published private(set) var progress: Double = 0
    var onComplete: (() -> Void)?
    private var startedAt: TimeInterval?
    private var timer: Timer?

    func begin() {
        guard startedAt == nil else { return }
        startedAt = ProcessInfo.processInfo.systemUptime
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let s = startedAt else { return }
        let p = min(1, (ProcessInfo.processInfo.systemUptime - s) / Self.duration)
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
    private var startedAt: TimeInterval = 0
    private var timer: Timer?
    private let onDone: () -> Void

    init(total: TimeInterval, onDone: @escaping () -> Void) {
        self.total = max(total, 0.1)
        self.remaining = total
        self.onDone = onDone
    }

    var progress: Double { 1 - remaining / total }

    func start() {
        startedAt = ProcessInfo.processInfo.systemUptime
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        remaining = max(0, total - (ProcessInfo.processInfo.systemUptime - startedAt))
        if remaining <= 0 { stop(); onDone() }
    }
}
