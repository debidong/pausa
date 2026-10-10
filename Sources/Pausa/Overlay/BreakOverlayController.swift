import AppKit
import SwiftUI

/// Break UI. Short break = small capsule near the cursor + a light click-through
/// dim on every screen; never takes focus. Long break = one window per screen
/// at .screenSaver level with copy, countdown ring, 「推迟 5 分钟」「跳过」.
///
/// All methods must be called on the main thread. Showing a new break replaces
/// any break currently on screen.
public final class BreakOverlayController {
    public enum Copy {
        public static let short = "看看 6 米外，眨眨眼"
        public static let long = "起来走动 3 分钟"
        public static let longSubtitle = "喝口水，活动一下肩颈。"
        public static let snooze = "推迟 5 分钟"
        public static let skip = "跳过"
    }

    private enum Mode {
        case short
        case long(onSnooze: () -> Void, onSkip: () -> Void)
    }

    private var mode: Mode?
    private var countdown: Countdown?
    private var onFinish: (() -> Void)?
    private var dimWindows: [NSWindow] = []
    private var capsule: NSPanel?
    private var longWindows: [NSWindow] = []
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

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var fadeDuration: TimeInterval { reduceMotion ? 0 : 1.0 }

    // MARK: Short break

    /// Capsule near the cursor + slight dim. `onFinish` fires when time is up.
    public func showShort(duration: TimeInterval, onFinish: (() -> Void)? = nil) {
        dismiss(animated: false)
        mode = .short
        self.onFinish = onFinish
        let cd = Countdown(total: duration) { [weak self] in self?.finish() }
        countdown = cd

        dimWindows = NSScreen.screens.map(makeDimWindow)
        let panel = makeCapsule(countdown: cd)
        capsule = panel
        fadeIn(dimWindows + [panel], short: true)
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
        let windows = dimWindows + longWindows + (capsule.map { [$0] } ?? [])
        dimWindows = []; longWindows = []; capsule = nil
        fadeOut(windows, animated: animated)
        if wasLong { restorePreviousApp() }
    }

    // MARK: internals

    private func finish() {
        let cb = onFinish
        dismiss()
        cb?()
    }

    private func snooze() {
        guard case .long(let onSnooze, _) = mode else { return }
        dismiss(); onSnooze()
    }

    private func skip() {
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
            let w = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.animationBehavior = .none
            let view = LongBreakView(countdown: cd, showControls: screen == primary,
                                     onSnooze: { [weak self] in self?.snooze() },
                                     onSkip: { [weak self] in self?.skip() })
            w.contentView = NSHostingView(rootView: view)
            w.alphaValue = 0
            return w
        }
    }

    private func makeDimWindow(for screen: NSScreen) -> NSWindow {
        let w = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.setFrame(screen.frame, display: false)
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.ignoresMouseEvents = true
        w.isOpaque = false
        w.hasShadow = false
        w.backgroundColor = NSColor.black.withAlphaComponent(0.12)
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.alphaValue = 0
        return w
    }

    private func makeCapsule(countdown: Countdown) -> NSPanel {
        let host = NSHostingView(rootView: ShortBreakCapsule(countdown: countdown))
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        var origin = NSPoint(x: mouse.x + 18, y: mouse.y - size.height - 18)
        let vf = screen.visibleFrame
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)

        let p = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar + 1
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true
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

    private func fadeIn(_ windows: [NSWindow], short: Bool) {
        windows.forEach { $0.orderFrontRegardless() }
        let d = short ? min(fadeDuration, 0.35) : fadeDuration
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

/// Borderless window that can take key so buttons respond on first click.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
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
