import SwiftUI
import AppKit
import PausaCore

// Pre-break reminder: a black panel at the top centre of the screen that grows out of the notch.
// Display only. Every number and every decision to show comes from `PausaCore.PreBreakState`,
// computed by the Scheduler on each tick; nothing here counts time or allowance.
// Spec: /workspace/pausa-prebreak-notch/spec.md (v1.0), prototype: index.html next to it.

// MARK: - Metrics and placement

enum PanelMetrics {
    static let width: CGFloat = 360
    static let radius: CGFloat = 24
    static let hPad: CGFloat = 20, topGap: CGFloat = 10, bottomPad: CGFloat = 20
    static let contentWidth: CGFloat = 320
    static let rowGap: CGFloat = 14
    /// Blank top row on a screen without a notch.
    static let flatTopRow: CGFloat = 32
    /// Start width of the grow animation on a screen without a notch (prototype value).
    static let flatStartWidth: CGFloat = 185
    static let notchRadius: CGFloat = 10
    // Shadow (CSS: 0 12px 32px rgba(0,0,0,.4); Core Animation's radius is half the CSS blur).
    static let shadowRadius: CGFloat = 16, shadowY: CGFloat = 12, shadowOpacity: Float = 0.4
    static let shadowSide: CGFloat = 56, shadowBottom: CGFloat = 80
}

/// Where the panel sits on one screen. Pure, so the self-test can feed it made-up notches.
struct PanelPlacement: Equatable {
    var hasNotch: Bool
    /// Height of the blank row at the top of the panel.
    var topRow: CGFloat
    /// Screen x of the panel's centre line.
    var centerX: CGFloat
    /// Width of the hardware notch, the start width of the grow animation. nil without a notch.
    var notchWidth: CGFloat?

    static func compute(frame: NSRect, safeTop: CGFloat, auxLeft: NSRect?, auxRight: NSRect?) -> PanelPlacement {
        if safeTop > 0, let l = auxLeft, let r = auxRight {
            let w = r.minX - l.maxX
            // A notch as wide as the panel would leave no room: treat it as no notch (spec 2.2).
            if w > 0, w < PanelMetrics.width {
                return PanelPlacement(hasNotch: true, topRow: safeTop, centerX: (l.maxX + r.minX) / 2, notchWidth: w)
            }
        }
        return PanelPlacement(hasNotch: false, topRow: PanelMetrics.flatTopRow, centerX: frame.midX, notchWidth: nil)
    }
}

extension NSScreen {
    var panelPlacement: PanelPlacement {
        .compute(frame: frame, safeTop: safeAreaInsets.top, auxLeft: auxiliaryTopLeftArea, auxRight: auxiliaryTopRightArea)
    }
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// The panel outline: flat top edge, rounded bottom corners. The same command sequence for every radius,
/// so Core Animation can interpolate between two of them. `yUp`: top is maxY (layers in a non-flipped view);
/// otherwise top is minY (SwiftUI).
enum PanelPath {
    static func make(_ r: CGRect, radius: CGFloat, yUp: Bool) -> CGPath {
        let k: CGFloat = 0.5522847498
        let rad = max(1, min(radius, r.width / 2, r.height))
        let top = yUp ? r.maxY : r.minY, bot = yUp ? r.minY : r.maxY
        let up: CGFloat = yUp ? 1 : -1
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX, y: top))
        p.addLine(to: CGPoint(x: r.maxX, y: top))
        p.addLine(to: CGPoint(x: r.maxX, y: bot + up * rad))
        p.addCurve(to: CGPoint(x: r.maxX - rad, y: bot),
                   control1: CGPoint(x: r.maxX, y: bot + up * rad * (1 - k)),
                   control2: CGPoint(x: r.maxX - rad * (1 - k), y: bot))
        p.addLine(to: CGPoint(x: r.minX + rad, y: bot))
        p.addCurve(to: CGPoint(x: r.minX, y: bot + up * rad),
                   control1: CGPoint(x: r.minX + rad * (1 - k), y: bot),
                   control2: CGPoint(x: r.minX, y: bot + up * rad * (1 - k)))
        p.closeSubpath()
        return p
    }
}

struct PanelShape: Shape {
    var radius: CGFloat = PanelMetrics.radius
    func path(in rect: CGRect) -> Path { Path(PanelPath.make(rect, radius: radius, yUp: false)) }
}

// MARK: - Buttons: which ones, and how they wrap

enum PanelButton: Equatable {
    case skip, snooze(Int), snoozeUsedUp, now

    /// Left to right (spec section 3). The view shows exactly this list.
    static func set(for s: PreBreakState) -> [PanelButton] {
        var b: [PanelButton] = []
        if s.canSkip && !s.atHardLine { b.append(.skip) }
        switch s.snooze {
        case .available(let m): b.append(.snooze(m))
        case .usedUp: b.append(.snoozeUsedUp)
        case .hidden: break
        }
        b.append(.now)
        return b
    }

    var title: String {
        switch self {
        case .skip: return L("prebreak.skip")
        case .snooze(let m): return L("prebreak.postpone", m)
        case .snoozeUsedUp: return L("prebreak.postponeUsedUp")
        case .now: return L("menu.breakNow")
        }
    }
    var isSnooze: Bool { if case .snooze = self { return true }; return self == .snoozeUsedUp }
    var hPad: CGFloat { self == .now ? 18 : 12 }
    var weight: NSFont.Weight { self == .now ? .semibold : .medium }
}

enum PanelText {
    static func width(_ s: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }
}

/// How the button row fits into 320 pt (spec 2.3).
enum RowLayout: Equatable {
    case single        // one row
    case noteBelow     // rule 1: 「不能再延后」 drops to its own line under the other buttons
    case wrapNow       // rule 2: 「现在休息」 on a second row
    case stackAll      // rule 3: one button per row

    static func gap(before i: Int, in b: [PanelButton]) -> CGFloat {
        guard i > 0 else { return 0 }
        if b[i] == .now { return 8 }
        if b[i].isSnooze, b[i - 1] == .skip { return 2 }
        return 0
    }

    static func width(of b: [PanelButton]) -> CGFloat {
        b.enumerated().reduce(0) { acc, e in
            acc + gap(before: e.offset, in: b) + PanelText.width(e.element.title, size: 13, weight: e.element.weight) + 2 * e.element.hPad
        }
    }

    static func choose(_ b: [PanelButton], avail: CGFloat = PanelMetrics.contentWidth) -> RowLayout {
        if width(of: b) <= avail { return .single }
        if b.contains(.snoozeUsedUp) {
            if width(of: b.filter { $0 != .snoozeUsedUp }) <= avail { return .noteBelow }
        } else if b.contains(where: { $0.isSnooze }) {
            let top = b.filter { $0 != .now }
            if width(of: top) <= avail, width(of: [.now]) <= avail { return .wrapNow }
        }
        return .stackAll
    }
}

// MARK: - Copy

enum PreBreakCopy {
    /// 「短休息将在 N 秒后开始」, split at the formatted number so the three parts can be set in three styles.
    /// One string per language, so word order is the translator's call (spec 10.1).
    static func sentence(_ k: BreakKind, seconds n: Int) -> (before: String, number: String, after: String) {
        let full = L(k == .short ? "prebreak.startsIn.short" : "prebreak.startsIn.long", n)
        let num = String(n)
        guard let r = full.range(of: num) else { return (full, "", "") }
        // A space next to the number must survive the layout: use no-break spaces at the cut.
        func keep(_ s: String, leading: Bool) -> String {
            var t = s
            if leading, t.hasSuffix(" ") { t.removeLast(); t += "\u{00A0}" }
            if !leading, t.hasPrefix(" ") { t.removeFirst(); t = "\u{00A0}" + t }
            return t
        }
        return (keep(String(full[..<r.lowerBound]), leading: true), num, keep(String(full[r.upperBound...]), leading: false))
    }
    static func spoken(_ k: BreakKind, seconds n: Int) -> String {
        L(k == .short ? "prebreak.startsIn.short" : "prebreak.startsIn.long", n)
    }
    static var hardLine: String { L("break.hardLine") }
    static func pill(_ s: Int) -> String { L("pill.countdown", s) }
    static var typing: String { L("pill.typing") }
}

/// Live model the views observe, so each tick redraws without rebuilding the windows.
@MainActor
final class PreBreakModel: ObservableObject {
    @Published var state: PreBreakState
    init(_ s: PreBreakState) { state = s }
}

// MARK: - Views

struct PreBreakActions {
    var skip: () -> Void = {}
    var snooze: () -> Void = {}
    var now: () -> Void = {}
}

private let hardLineOrange = Color(red: 1, green: 0x9F / 255, blue: 0x0A / 255)   // #FF9F0A

struct PanelButtonView: View {
    let kind: PanelButton
    let action: () -> Void
    @State private var hover = false

    private var disabled: Bool { kind == .snoozeUsedUp }
    private var fg: Color {
        switch kind {
        case .skip: return .white.opacity(hover ? 0.75 : 0.45)
        case .snooze: return .white.opacity(hover ? 1 : 0.75)
        case .snoozeUsedUp: return .white.opacity(0.3)
        case .now: return .black
        }
    }
    private var bg: Color {
        switch kind {
        case .now: return hover ? Color(white: 0xE8 / 255.0) : .white
        case .snooze: return hover ? .white.opacity(0.08) : .clear
        default: return .clear
        }
    }

    var body: some View {
        Button(action: action) {
            Text(kind.title)
                .font(.system(size: 13, weight: kind == .now ? .semibold : .medium))
                .foregroundColor(fg)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, kind.hPad)
                .frame(height: 32)
                .background(Capsule().fill(bg))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(disabled)
        .onHover { hover = $0 && !disabled }
    }
}

/// The first line: three type styles on one baseline, the number in a box that keeps its width.
struct PanelSentence: View {
    let kind: BreakKind
    let seconds: Int
    private var parts: (before: String, number: String, after: String) { PreBreakCopy.sentence(kind, seconds: seconds) }

    /// 1 down to 0.8 when a language's sentence is wider than 320 (zh and en never are).
    private var scale: CGFloat {
        let p = parts
        let w = PanelText.width(p.before, size: 15, weight: .regular) + max(26, PanelText.width(p.number, size: 20, weight: .semibold))
            + PanelText.width(p.after, size: 13, weight: .regular)
        return w <= PanelMetrics.contentWidth ? 1 : max(0.8, PanelMetrics.contentWidth / w)
    }

    var body: some View {
        let p = parts
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if !p.before.isEmpty { Text(p.before).font(.system(size: 15)).foregroundColor(.white.opacity(0.85)) }
            Text(p.number).font(.system(size: 20, weight: .semibold).monospacedDigit()).foregroundColor(.white)
                .frame(width: 26)
            if !p.after.isEmpty { Text(p.after).font(.system(size: 13)).foregroundColor(.white.opacity(0.6)) }
        }
        .lineLimit(1).fixedSize()
        .scaleEffect(scale)
        .frame(height: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PreBreakCopy.spoken(kind, seconds: seconds))
    }
}

/// Everything on the black panel except the black itself: the blank top row, the sentence, the buttons.
struct PreBreakContentView: View {
    @ObservedObject var model: PreBreakModel
    var topRow: CGFloat
    var actions = PreBreakActions()

    private var s: PreBreakState { model.state }

    var body: some View {
        VStack(spacing: PanelMetrics.rowGap) {
            PanelSentence(kind: s.kind, seconds: s.secondsLeft)
            if s.atHardLine {
                Text(PreBreakCopy.hardLine)
                    .font(.system(size: 12.5)).lineSpacing(3).foregroundColor(hardLineOrange)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300)
                    .padding(.top, -4)   // 10 pt under the sentence, 14 above the buttons
            }
            buttons
        }
        .frame(width: PanelMetrics.contentWidth)
        .padding(.top, topRow + PanelMetrics.topGap)
        .padding(.horizontal, PanelMetrics.hPad)
        .padding(.bottom, PanelMetrics.bottomPad)
        .frame(width: PanelMetrics.width)
    }

    private func button(_ b: PanelButton) -> some View {
        PanelButtonView(kind: b) {
            switch b {
            case .skip: actions.skip()
            case .snooze: actions.snooze()
            case .now: actions.now()
            case .snoozeUsedUp: break
            }
        }
    }

    private func row(_ b: [PanelButton]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(b.enumerated()), id: \.offset) { i, x in
                button(x).padding(.leading, RowLayout.gap(before: i, in: b))
            }
        }
    }

    private var note: some View {
        Text(PanelButton.snoozeUsedUp.title)
            .font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.3))
            .lineLimit(1).fixedSize().frame(height: 16)
    }

    @ViewBuilder private var buttons: some View {
        let b = PanelButton.set(for: s)
        switch RowLayout.choose(b) {
        case .single:
            row(b)
        case .noteBelow:
            VStack(spacing: 8) { row(b.filter { $0 != .snoozeUsedUp }); note }
        case .wrapNow:
            VStack(spacing: 6) { row(b.filter { $0 != .now }); row([.now]) }
        case .stackAll:
            VStack(spacing: 6) { ForEach(Array(b.enumerated()), id: \.offset) { _, x in row([x]) } }
        }
    }
}

/// The cursor pill for the last 10 seconds: black capsule, white text, no icon.
struct CursorPill: View {
    @ObservedObject var model: PreBreakModel
    var body: some View {
        Text(model.state.typingWait ? PreBreakCopy.typing : PreBreakCopy.pill(max(0, model.state.secondsLeft)))
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundColor(.white)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.black))
    }
}

// MARK: - Windows

/// Non-activating, never key: a click lands, the frontmost app keeps the keyboard.
private final class PreBreakPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// A borderless window at the screen's top edge would otherwise be pushed below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// One click is enough even though the panel never becomes key.
private final class FirstMouseHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Everything that is on screen for one open panel.
@MainActor
private final class OpenPanel {
    let displayID: CGDirectDisplayID?
    var placement: PanelPlacement
    var height: CGFloat
    let body: PreBreakPanel
    let shadow: PreBreakPanel
    let bodyShape = CAShapeLayer()
    let shadowShape = CAShapeLayer()
    let content: FirstMouseHost<AnyView>
    var screenFrame: NSRect

    init(screen: NSScreen, model: PreBreakModel, actions: PreBreakActions) {
        displayID = screen.displayID
        placement = screen.panelPlacement
        screenFrame = screen.frame
        content = FirstMouseHost(rootView: AnyView(PreBreakContentView(model: model, topRow: placement.topRow, actions: actions)
            .environment(\.locale, AppLanguage.current.locale)))
        height = ceil(content.fittingSize.height)
        body = PreBreakPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        shadow = PreBreakPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        for p in [body, shadow] {
            PreBreakController.configure(p)
        }
        shadow.ignoresMouseEvents = true      // the shadow margin never takes a click

        let bodyRoot = NSView(frame: .zero)
        bodyRoot.wantsLayer = true
        bodyShape.fillColor = NSColor.black.cgColor
        bodyRoot.layer?.addSublayer(bodyShape)
        content.wantsLayer = true
        content.autoresizingMask = [.width, .height]
        bodyRoot.addSubview(content)
        body.contentView = bodyRoot

        let shadowRoot = NSView(frame: .zero)
        shadowRoot.wantsLayer = true
        shadowShape.fillColor = NSColor.black.cgColor
        shadowShape.shadowColor = NSColor.black.cgColor
        shadowShape.shadowOpacity = PanelMetrics.shadowOpacity
        shadowShape.shadowRadius = PanelMetrics.shadowRadius
        shadowShape.shadowOffset = CGSize(width: 0, height: -PanelMetrics.shadowY)
        shadowRoot.layer?.addSublayer(shadowShape)
        shadow.contentView = shadowRoot
        layout()
    }

    var panelRect: NSRect {
        NSRect(x: placement.centerX - PanelMetrics.width / 2, y: screenFrame.maxY - height,
               width: PanelMetrics.width, height: height)
    }
    /// Panel rectangle in the shadow window's coordinates.
    var shadowLocal: CGRect { CGRect(x: PanelMetrics.shadowSide, y: PanelMetrics.shadowBottom, width: PanelMetrics.width, height: height) }
    var bodyLocal: CGRect { CGRect(x: 0, y: 0, width: PanelMetrics.width, height: height) }

    /// Start outline of the grow animation, in the given local rectangle.
    func startPath(in local: CGRect) -> CGPath {
        let w = placement.notchWidth ?? PanelMetrics.flatStartWidth
        let h = placement.hasNotch ? placement.topRow : max(1, (height * 0.02).rounded())
        let r = CGRect(x: local.midX - w / 2, y: local.maxY - h, width: w, height: h)
        return PanelPath.make(r, radius: min(PanelMetrics.notchRadius, h / 2), yUp: true)
    }
    func finalPath(in local: CGRect) -> CGPath { PanelPath.make(local, radius: PanelMetrics.radius, yUp: true) }

    /// Frames and final outlines, no animation.
    func layout() {
        let pr = panelRect
        body.setFrame(pr, display: false)
        shadow.setFrame(NSRect(x: pr.minX - PanelMetrics.shadowSide, y: pr.minY - PanelMetrics.shadowBottom,
                               width: pr.width + 2 * PanelMetrics.shadowSide, height: pr.height + PanelMetrics.shadowBottom), display: false)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bodyShape.frame = CGRect(origin: .zero, size: pr.size)
        bodyShape.path = finalPath(in: bodyLocal)
        shadowShape.frame = CGRect(origin: .zero, size: shadow.frame.size)
        let p = finalPath(in: shadowLocal)
        shadowShape.path = p; shadowShape.shadowPath = p
        CATransaction.commit()
        content.frame = CGRect(origin: .zero, size: pr.size)
    }

    func orderFront() {
        shadow.orderFrontRegardless()
        body.order(.above, relativeTo: shadow.windowNumber)
    }
    func orderOut() { body.orderOut(nil); shadow.orderOut(nil) }
}

/// Owns the panel and the pill. AppController calls `update` after every scheduler change.
@MainActor
final class PreBreakController {
    enum Removal { case animated, immediate }

    var onStartNow: () -> Void = {}
    var onPostpone: () -> Void = {}
    var onSkip: () -> Void = {}

    private var model: PreBreakModel?
    private var panel: OpenPanel?
    private var retiring: OpenPanel?
    private var generation = 0
    private var pill: PreBreakPanel?
    private var pillTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    #if DEBUG
    /// Debug (`--debug-show-prebreak`): pin the screen instead of following the pointer.
    var screenOverride: (() -> NSScreen?)?
    #endif

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    /// nil = nothing to show. Hidden panels and pills follow `showCard` / `showPill`.
    func update(_ s: PreBreakState?, removal: Removal) {
        guard let s else { closePanel(removal); hidePill(); return }
        if let model { if model.state != s { model.state = s } } else { model = PreBreakModel(s) }
        if s.showCard {
            if panel == nil { openPanel() } else { resizeSoon() }
        } else {
            closePanel(removal)
        }
        if s.showPill { showPill() } else { hidePill() }
    }

    func dismissAll() { update(nil, removal: .immediate) }

    // MARK: Panel

    static func configure(_ p: NSPanel) {
        // Best effort only. Make no claim about screen sharing or recording.
        #if DEBUG
        p.sharingType = ProcessInfo.processInfo.environment["PAUSA_CAPTURABLE"] == "1" ? .readOnly : .none
        #else
        p.sharingType = .none
        #endif
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
    }

    private func pointerScreen() -> NSScreen? {
        #if DEBUG
        if let s = screenOverride?() { return s }
        #endif
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main
    }

    private var actions: PreBreakActions {
        PreBreakActions(skip: { [weak self] in self?.onSkip() },
                        snooze: { [weak self] in self?.onPostpone() },
                        now: { [weak self] in self?.onStartNow() })
    }

    private func openPanel() {
        guard let model, let screen = pointerScreen() else { return }
        retiring?.orderOut(); retiring = nil
        generation += 1
        let p = OpenPanel(screen: screen, model: model, actions: actions)
        panel = p
        grow(p)
        let s = model.state
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: PreBreakCopy.spoken(s.kind, seconds: s.secondsLeft),
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func grow(_ p: OpenPanel) {
        if reduceMotion {
            for w in [p.body, p.shadow] { w.alphaValue = 0 }
            p.orderFront()
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.2
                c.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.body.animator().alphaValue = 1
                p.shadow.animator().alphaValue = 1
            }
            return
        }
        let curve = CAMediaTimingFunction(controlPoints: 0.34, 1.3, 0.64, 1)
        func anim(_ key: String, from: CGPath, to: CGPath) -> CABasicAnimation {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from; a.toValue = to; a.duration = 0.35; a.timingFunction = curve
            return a
        }
        let bodyFinal = p.finalPath(in: p.bodyLocal), shadowFinal = p.finalPath(in: p.shadowLocal)
        CATransaction.begin()
        p.bodyShape.add(anim("path", from: p.startPath(in: p.bodyLocal), to: bodyFinal), forKey: "move")
        p.shadowShape.add(anim("path", from: p.startPath(in: p.shadowLocal), to: shadowFinal), forKey: "move")
        p.shadowShape.add(anim("shadowPath", from: p.startPath(in: p.shadowLocal), to: shadowFinal), forKey: "moveShadow")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.18
        fade.beginTime = CACurrentMediaTime() + 0.14; fade.fillMode = .backwards
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        p.content.layer?.add(fade, forKey: "fade")
        CATransaction.commit()
        p.orderFront()
    }

    private func closePanel(_ removal: Removal) {
        guard let p = panel else { return }
        panel = nil
        generation += 1
        if removal == .immediate { p.orderOut(); return }
        retiring?.orderOut()
        retiring = p
        let gen = generation
        let finish: () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen, self.retiring === p else { return }
                p.orderOut(); self.retiring = nil
            }
        }
        if reduceMotion {
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = 0.2
                c.timingFunction = CAMediaTimingFunction(name: .easeIn)
                p.body.animator().alphaValue = 0
                p.shadow.animator().alphaValue = 0
            }, completionHandler: finish)
            return
        }
        let curve = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
        func retract(_ layer: CAShapeLayer, _ key: String, _ to: CGPath) {
            let from = (layer.presentation()?.value(forKeyPath: key) as! CGPath?) ?? (layer.value(forKeyPath: key) as! CGPath?)
            layer.setValue(to, forKeyPath: key)
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from; a.toValue = to; a.duration = 0.25; a.timingFunction = curve
            layer.add(a, forKey: "move" + key)
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock(finish)
        let bodyStart = p.startPath(in: p.bodyLocal), shadowStart = p.startPath(in: p.shadowLocal)
        retract(p.bodyShape, "path", bodyStart)
        retract(p.shadowShape, "path", shadowStart)
        retract(p.shadowShape, "shadowPath", shadowStart)
        let from = p.content.layer?.presentation()?.opacity ?? 1
        p.content.layer?.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from; fade.toValue = 0; fade.duration = 0.09
        fade.timingFunction = CAMediaTimingFunction(name: .linear)
        p.content.layer?.add(fade, forKey: "fadeOut")
        CATransaction.commit()
    }

    /// The content can change height while the panel is up (the 90-minute line appears): follow it, no animation.
    private func resizeSoon() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let p = self.panel else { return }
                let h = ceil(p.content.fittingSize.height)
                if abs(h - p.height) > 0.5 { p.height = h; p.layout() }
            }
        }
    }

    /// Display set-up changed (spec 6.3): re-place on the same screen, or move to the pointer's screen.
    private func screensChanged() {
        guard let p = panel, let model else { return }
        if let id = p.displayID, let s = NSScreen.screens.first(where: { $0.displayID == id }) {
            p.placement = s.panelPlacement
            p.screenFrame = s.frame
            p.layout()
        } else {
            closePanel(.immediate)
            if model.state.showCard, model.state.secondsLeft >= PreBreakState.minOpenSeconds { openPanel() }
        }
    }

    // MARK: Pill (appears and disappears at once)

    private func showPill() {
        guard pill == nil, let model else { return }
        let host = NSHostingView(rootView: CursorPill(model: model)
            .shadow(color: .black.opacity(0.4), radius: 7, x: 0, y: 4).padding(PreBreakController.pillInset)
            .environment(\.locale, AppLanguage.current.locale))
        let p = PreBreakPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        Self.configure(p)
        p.ignoresMouseEvents = true          // clicks fall through to the app below
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
        pill?.orderOut(nil)
        pill = nil
    }

    /// (+16, −20) from the pointer; flips left / above near an edge; always inside the pointer's screen.
    private func follow() {
        guard let p = pill, let host = p.contentView else { return }
        let size = host.fittingSize
        let m = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) else { return }
        p.setFrame(Self.pillFrame(mouse: m, size: size, in: screen.frame), display: true)
    }

    /// Room around the capsule for its shadow.
    static let pillInset: CGFloat = 12

    /// Pure geometry (size includes the shadow margin). Exposed for the debug self-test.
    static func pillFrame(mouse m: NSPoint, size: NSSize, in sf: NSRect) -> NSRect {
        let inset = pillInset
        var x = m.x + 16 - inset
        var y = m.y - 20 - (size.height - inset)            // top of the pill 20 pt under the pointer
        if x + size.width > sf.maxX { x = m.x - 16 - size.width + inset }
        if y < sf.minY { y = m.y + 20 - inset }
        x = min(max(x, sf.minX), sf.maxX - size.width)
        y = min(max(y, sf.minY), sf.maxY - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

// MARK: - Offscreen renders (no windows)

#if DEBUG
/// The panel as one SwiftUI picture, for renders: shadow, black, then the content. The live windows draw the same
/// outline with Core Animation layers; both come from `PanelPath`.
struct PreBreakComposite: View {
    @ObservedObject var model: PreBreakModel
    var placement: PanelPlacement
    var height: CGFloat
    var body: some View {
        ZStack(alignment: .top) {
            PanelShape().fill(Color.black)
                .frame(width: PanelMetrics.width, height: height)
                .shadow(color: .black.opacity(Double(PanelMetrics.shadowOpacity)), radius: PanelMetrics.shadowRadius, x: 0, y: PanelMetrics.shadowY)
            PreBreakContentView(model: model, topRow: placement.topRow)
        }
        .frame(width: PanelMetrics.width, height: height, alignment: .top)
    }
}

@MainActor
enum PreBreakSnapshots {
    static let backdrop = Color(red: 0x1B / 255, green: 0x1B / 255, blue: 0x1D / 255)   // prototype page background

    static func state(_ kind: BreakKind, snooze: PreBreakState.Snooze, hardLine: Bool = false, seconds: Int = 24) -> PreBreakState {
        PreBreakState(kind: kind, secondsLeft: seconds, snooze: snooze, canSkip: kind == .short && !hardLine,
                      atHardLine: hardLine, typingWait: false, showCard: true, showPill: false)
    }

    /// (file stem, state): the four states of the render matrix.
    static let cases: [(String, PreBreakState)] = [
        ("short", state(.short, snooze: .available(minutes: 5))),
        ("short-usedup", state(.short, snooze: .usedUp)),
        ("long", state(.long, snooze: .available(minutes: 5))),
        ("90min", state(.long, snooze: .hidden, hardLine: true)),
    ]

    /// A bitmap of `view` at 2x, drawn without a window.
    static func png<V: View>(_ view: V, to url: URL) {
        let host = NSHostingView(rootView: view.environment(\.locale, AppLanguage.current.locale))
        host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { print("render failed: \(url.lastPathComponent)"); return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { print("render failed: \(url.lastPathComponent)"); return }
        try? data.write(to: url)
        print("wrote \(url.path)")
    }

    static func panelHeight(_ s: PreBreakState, topRow: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: PreBreakContentView(model: PreBreakModel(s), topRow: topRow))
        return ceil(host.fittingSize.height)
    }

    /// One render: the panel with a margin, the notch sketch on top when the screen has one.
    static func scene(_ s: PreBreakState, notch: Bool) -> some View {
        let placement = PanelPlacement(hasNotch: notch, topRow: 32, centerX: 0, notchWidth: notch ? 185 : nil)
        let h = panelHeight(s, topRow: 32)
        return ZStack(alignment: .top) {
            backdrop
            if notch {
                PanelShape(radius: PanelMetrics.notchRadius).fill(Color.black).frame(width: 185, height: 32)
            }
            PreBreakComposite(model: PreBreakModel(s), placement: placement, height: h)
        }
        .frame(width: PanelMetrics.width + 2 * 56, height: h + 80, alignment: .top)
    }

    /// 16 panels: zh/en × notch/no notch × the four states (spec 12.1).
    static func writePanels(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let saved = AppLanguage.override
        defer { AppLanguage.override = saved }
        for (lang, tag) in [(AppLanguage.zhHans, "zh"), (.en, "en")] {
            AppLanguage.override = lang
            for notch in [true, false] {
                for (stem, st) in cases {
                    png(scene(st, notch: notch), to: dir.appendingPathComponent("\(tag)-\(notch ? "notch" : "nonotch")-\(stem).png"))
                }
            }
        }
    }

    /// 4 pills: {zh, en} × {countdown N = 7, typing} (spec 12.2).
    static func writePills(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let saved = AppLanguage.override
        defer { AppLanguage.override = saved }
        for (lang, tag) in [(AppLanguage.zhHans, "zh"), (.en, "en")] {
            AppLanguage.override = lang
            for (name, typing) in [("countdown", false), ("typing", true)] {
                var st = state(.short, snooze: .available(minutes: 5), seconds: 7)
                st.typingWait = typing
                let v = CursorPill(model: PreBreakModel(st)).shadow(color: .black.opacity(0.4), radius: 7, x: 0, y: 4)
                    .padding(24).background(backdrop)
                png(v, to: dir.appendingPathComponent("\(tag)-pill-\(name).png"))
            }
        }
    }

    /// Window-free checks (spec 12.3).
    static func selftest() -> Bool {
        var ok = true
        func check(_ c: Bool, _ name: String) { print(c ? "ok   \(name)" : "FAIL \(name)"); ok = ok && c }
        let saved = AppLanguage.override
        defer { AppLanguage.override = saved }

        // Pill geometry.
        let sf = NSRect(x: 0, y: 0, width: 1440, height: 900), size = NSSize(width: 140, height: 46)
        let mid = PreBreakController.pillFrame(mouse: NSPoint(x: 700, y: 450), size: size, in: sf)
        check(mid.minX == 704 && mid.maxY == 442, "pill sits at (+16, −20) from the pointer")
        let corner = PreBreakController.pillFrame(mouse: NSPoint(x: 1435, y: 3), size: size, in: sf)
        check(sf.contains(corner) && corner.maxX <= 1435 && corner.minY >= 3, "pill flips left and up in the bottom-right corner")
        let second = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        check(second.contains(PreBreakController.pillFrame(mouse: NSPoint(x: 1441, y: 1079), size: size, in: second)),
              "pill stays inside the pointer's screen")

        // 1. Button sets and order per state.
        let c = cases.map { $0.1 }
        check(PanelButton.set(for: c[0]) == [.skip, .snooze(5), .now], "S1: skip · snooze · now")
        check(PanelButton.set(for: c[1]) == [.skip, .snoozeUsedUp, .now], "S2: skip · can't snooze · now")
        check(PanelButton.set(for: c[2]) == [.snooze(5), .now], "S3: snooze · now")
        check(PanelButton.set(for: state(.long, snooze: .usedUp)) == [.snoozeUsedUp, .now], "S4: can't snooze · now")
        check(PanelButton.set(for: c[3]) == [.now], "S5: now only")

        // 2. English S2 puts the note on its own line, Chinese does not.
        AppLanguage.override = .en
        let enS2 = RowLayout.choose(PanelButton.set(for: c[1]))
        print("     en S2 single-row width \(RowLayout.width(of: PanelButton.set(for: c[1])))")
        check(enS2 == .noteBelow, "English S2 uses the note-below layout")
        AppLanguage.override = .zhHans
        check(RowLayout.choose(PanelButton.set(for: c[1])) == .single, "Chinese S2 stays on one row")
        check(RowLayout.choose(PanelButton.set(for: c[0])) == .single, "Chinese S1 stays on one row")

        // 3. Width is 360 in all 16 renders.
        var widths = Set<CGFloat>()
        for lang in [AppLanguage.zhHans, .en] {
            AppLanguage.override = lang
            for (_, st) in cases {
                let host = NSHostingView(rootView: PreBreakContentView(model: PreBreakModel(st), topRow: 32))
                widths.insert(host.fittingSize.width)
            }
        }
        check(widths == [PanelMetrics.width], "content is 360 pt wide in every state and language (\(widths))")

        // 4. The blank row follows the notch height: 32 and 38.
        AppLanguage.override = .zhHans
        let h32 = panelHeight(c[0], topRow: 32), h38 = panelHeight(c[0], topRow: 38)
        check(h38 - h32 == 6, "a 38 pt notch makes the panel 6 pt taller than a 32 pt one")
        func notch(_ top: CGFloat, w: CGFloat) -> PanelPlacement {
            let f = NSRect(x: 0, y: 0, width: 1512, height: 982), mid = f.midX
            return .compute(frame: f, safeTop: top,
                            auxLeft: NSRect(x: 0, y: 950, width: mid - w / 2, height: top),
                            auxRight: NSRect(x: mid + w / 2, y: 950, width: mid - w / 2, height: top))
        }
        check(notch(32, w: 185).topRow == 32 && notch(38, w: 185).topRow == 38, "blank row equals safeAreaInsets.top")
        check(notch(32, w: 185).centerX == 756 && notch(32, w: 185).notchWidth == 185, "centre and width come from the aux areas")
        // 5. A notch as wide as the panel counts as no notch.
        let wide = notch(32, w: 360)
        check(!wide.hasNotch && wide.topRow == 32 && wide.centerX == 756, "a 360 pt notch is treated as no notch")
        let none = PanelPlacement.compute(frame: NSRect(x: 100, y: 0, width: 1000, height: 800), safeTop: 0, auxLeft: nil, auxRight: nil)
        check(!none.hasNotch && none.centerX == 600 && none.topRow == 32, "no notch: centred on the screen, 32 pt blank row")

        // Sentence does not jump when 10 becomes 9.
        for lang in [AppLanguage.zhHans, .en] {
            AppLanguage.override = lang
            let a = NSHostingView(rootView: PanelSentence(kind: .short, seconds: 10)).fittingSize.width
            let b = NSHostingView(rootView: PanelSentence(kind: .short, seconds: 9)).fittingSize.width
            check(abs(a - b) <= 0.5, "\(lang.rawValue): 10 → 9 moves the sentence by \(abs(a - b)) pt (≤ 0.5)")
        }
        // Outline: same command count at any radius (so Core Animation can interpolate).
        let p1 = PanelPath.make(CGRect(x: 0, y: 0, width: 185, height: 32), radius: 10, yUp: true)
        let p2 = PanelPath.make(CGRect(x: 0, y: 0, width: 360, height: 170), radius: 24, yUp: true)
        func count(_ p: CGPath) -> Int { var n = 0; p.applyWithBlock { _ in n += 1 }; return n }
        check(count(p1) == count(p2), "start and end outlines have the same structure")
        return ok
    }
}
#endif
