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
    /// Concave top fillet ears so the black shell melts seamlessly into the top screen bezel / notch.
    static let earRadius: CGFloat = 12
    static let startEarRadius: CGFloat = 8
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

/// The panel outline: top edge with concave liquid fillet ears (`±ear`) + rounded bottom corners (`radius`).
/// Emits the exact same 10-command sequence for every `(radius, ear)` pair so Core Animation interpolates smoothly.
/// `yUp`: top is maxY (layers in a non-flipped view); otherwise top is minY (SwiftUI).
enum PanelPath {
    static func make(_ r: CGRect, radius: CGFloat, ear: CGFloat = PanelMetrics.earRadius, yUp: Bool) -> CGPath {
        let k: CGFloat = 0.5522847498
        let e = max(0, min(ear, r.height * 0.45))
        let rad = max(1, min(radius, r.width / 2, max(1, r.height - e)))
        let top = yUp ? r.maxY : r.minY, bot = yUp ? r.minY : r.maxY
        let down: CGFloat = yUp ? -1 : 1
        let up: CGFloat = -down
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX - e, y: top))
        p.addLine(to: CGPoint(x: r.maxX + e, y: top))
        p.addCurve(to: CGPoint(x: r.maxX, y: top + down * e),
                   control1: CGPoint(x: r.maxX + e * (1 - k), y: top),
                   control2: CGPoint(x: r.maxX, y: top + down * e * (1 - k)))
        p.addLine(to: CGPoint(x: r.maxX, y: bot + up * rad))
        p.addCurve(to: CGPoint(x: r.maxX - rad, y: bot),
                   control1: CGPoint(x: r.maxX, y: bot + up * rad * (1 - k)),
                   control2: CGPoint(x: r.maxX - rad * (1 - k), y: bot))
        p.addLine(to: CGPoint(x: r.minX + rad, y: bot))
        p.addCurve(to: CGPoint(x: r.minX, y: bot + up * rad),
                   control1: CGPoint(x: r.minX + rad * (1 - k), y: bot),
                   control2: CGPoint(x: r.minX, y: bot + up * rad * (1 - k)))
        p.addLine(to: CGPoint(x: r.minX, y: top + down * e))
        p.addCurve(to: CGPoint(x: r.minX - e, y: top),
                   control1: CGPoint(x: r.minX, y: top + down * e * (1 - k)),
                   control2: CGPoint(x: r.minX - e * (1 - k), y: top))
        p.closeSubpath()
        return p
    }
}

struct PanelShape: Shape {
    var radius: CGFloat = PanelMetrics.radius
    var ear: CGFloat = PanelMetrics.earRadius
    func path(in rect: CGRect) -> Path { Path(PanelPath.make(rect, radius: radius, ear: ear, yUp: false)) }
}

// MARK: - Buttons: which ones, and how they wrap

enum PanelButton: Equatable {
    case skip, snooze(Int), snoozeUsedUp, urgent, now

    /// Left to right (spec section 3). The view shows exactly this list.
    static func set(for s: PreBreakState) -> [PanelButton] {
        var b: [PanelButton] = []
        if s.canSkip && !s.atHardLine { b.append(.skip) }
        switch s.snooze {
        case .available(let m): b.append(.snooze(m))
        case .usedUp: b.append(.snoozeUsedUp)
        case .hidden: if s.kind == .long && s.atHardLine { b.append(.urgent) }   // spec-hardline §5.2: in the snooze's place
        }
        b.append(.now)
        return b
    }

    var title: String {
        switch self {
        case .skip: return L("prebreak.skip")
        case .snooze(let m): return L("prebreak.postpone", m)
        case .snoozeUsedUp: return L("prebreak.postponeUsedUp")
        case .urgent: return L("break.urgentPause")
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
        if b[i].isSnooze, b[i - 1] == .skip { return 6 }
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
        } else if b.contains(where: { $0.isSnooze || $0 == .urgent }) {
            let top = b.filter { $0 != .now }
            if width(of: top) <= avail, width(of: [.now]) <= avail { return .wrapNow }
        }
        return .stackAll
    }
}

// MARK: - Copy

enum PreBreakCopy {
    private static func splitAround(_ num: String, in full: String) -> (before: String, number: String, after: String) {
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

    /// 「短休息将在 N 秒后开始」, split at the formatted number so the number rolls independently on one baseline.
    /// One string per language, so word order is the translator's call (spec 10.1).
    static func sentence(_ k: BreakKind, seconds n: Int) -> (before: String, number: String, after: String) {
        splitAround(String(n), in: L(k == .short ? "prebreak.startsIn.short" : "prebreak.startsIn.long", n))
    }
    static func spoken(_ k: BreakKind, seconds n: Int) -> String {
        L(k == .short ? "prebreak.startsIn.short" : "prebreak.startsIn.long", n)
    }
    static var hardLine: String { Settings.shared.hardLineText }
    /// The kind comes first and never changes while the digits tick: a glance at the pill tells short from long.
    static func pill(_ k: BreakKind, _ s: Int) -> String { L(k == .short ? "pill.countdown.short" : "pill.countdown.long", s) }
    static func pillParts(_ k: BreakKind, _ s: Int) -> (before: String, number: String, after: String) {
        splitAround(String(s), in: pill(k, s))
    }
    static func typing(_ k: BreakKind) -> String { L(k == .short ? "pill.typing.short" : "pill.typing.long") }
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
    var urgent: () -> Void = {}
    var now: () -> Void = {}
}

private let hardLineOrange = Color(red: 1, green: 0x9F / 255, blue: 0x0A / 255)   // #FF9F0A

private struct IslandButtonStyle: ButtonStyle {
    let disabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && !disabled && !reduceMotion
        configuration.label
            .scaleEffect(pressed ? 0.94 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.68), value: pressed)
    }
}

struct PanelButtonView: View {
    let kind: PanelButton
    let action: () -> Void
    @State private var hover = false

    private var disabled: Bool { kind == .snoozeUsedUp }
    private var fg: Color {
        switch kind {
        case .skip: return .white.opacity(hover ? 0.85 : 0.52)
        case .snooze, .urgent: return .white.opacity(hover ? 0.98 : 0.86)
        case .snoozeUsedUp: return .white.opacity(0.32)
        case .now: return .black
        }
    }
    private var bg: Color {
        switch kind {
        case .now: return hover ? Color(white: 0.91) : .white
        case .snooze, .urgent: return .white.opacity(hover ? 0.17 : 0.10)
        case .skip: return hover ? .white.opacity(0.07) : .clear
        case .snoozeUsedUp: return .clear
        }
    }
    private var border: Color {
        switch kind {
        case .snooze, .urgent: return .white.opacity(hover ? 0.25 : 0.14)
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
                .overlay(Capsule().strokeBorder(border, lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(IslandButtonStyle(disabled: disabled))
        .focusable(false)
        .disabled(disabled)
        .onHover { hover = $0 && !disabled }
    }
}

/// The first line: unified surrounding copy (`14.5pt medium`) + rolling `19pt semibold` digits in a fixed-width box.
struct PanelSentence: View {
    let kind: BreakKind
    let seconds: Int
    private var parts: (before: String, number: String, after: String) { PreBreakCopy.sentence(kind, seconds: seconds) }

    /// 1 down to 0.8 when a language's sentence is wider than 320 (zh and en never are).
    private var scale: CGFloat {
        let p = parts
        let w = PanelText.width(p.before, size: 14.5, weight: .medium) + max(26, PanelText.width(p.number, size: 19, weight: .semibold))
            + PanelText.width(p.after, size: 14.5, weight: .medium)
        return w <= PanelMetrics.contentWidth ? 1 : max(0.8, PanelMetrics.contentWidth / w)
    }

    var body: some View {
        let p = parts
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if !p.before.isEmpty { Text(p.before).font(.system(size: 14.5, weight: .medium)).foregroundColor(.white.opacity(0.78)) }
            RollingDigits(text: p.number, numericValue: Double(seconds), size: 19, weight: .semibold)
                .foregroundColor(.white)
                .frame(width: 26)
            if !p.after.isEmpty { Text(p.after).font(.system(size: 14.5, weight: .medium)).foregroundColor(.white.opacity(0.78)) }
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
            case .urgent: actions.urgent()
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

/// A frosted capsule behind the pill, the same `.popover` material as the menu bar popover. It follows the system
/// appearance, and Reduce Transparency is handled by the system. `.active` because the panel is never key.
private struct PillGlass: NSViewRepresentable {
    final class V: NSVisualEffectView {
        override func layout() {
            super.layout()
            wantsLayer = true
            layer?.cornerRadius = bounds.height / 2
            layer?.masksToBounds = true
        }
    }
    func makeNSView(context: Context) -> V {
        let v = V()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: V, context: Context) {}
}

/// The cursor pill for the last 10 seconds: frosted capsule, system text colour, no icon (Steve, appendix B).
struct CursorPill: View {
    @ObservedObject var model: PreBreakModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Group {
            if model.state.typingWait {
                Text(PreBreakCopy.typing(model.state.kind))
                    .font(.system(size: 12, weight: .semibold))
            } else {
                let sec = max(0, model.state.secondsLeft)
                let p = PreBreakCopy.pillParts(model.state.kind, sec)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if !p.before.isEmpty { Text(p.before).font(.system(size: 12, weight: .semibold)) }
                    RollingDigits(text: p.number, numericValue: Double(sec), size: 12, weight: .semibold)
                    if !p.after.isEmpty { Text(p.after).font(.system(size: 12, weight: .semibold)) }
                }
            }
        }
        .foregroundColor(.primary)
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 10).padding(.vertical, 5)
        // 35% solid between the glass and the text (white in light, black in dark): a white page or bright video
        // behind the pill can't wash the digits out (Steve, appendix B). Later .background sits further back.
        .background(Capsule().fill((scheme == .dark ? Color.black : Color.white).opacity(0.35)))
        .background(PillGlass())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.state.typingWait
            ? PreBreakCopy.typing(model.state.kind)
            : PreBreakCopy.pill(model.state.kind, max(0, model.state.secondsLeft)))
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
    let rimGradient = CAGradientLayer()
    let rimMask = CAShapeLayer()
    let contentHolder = NSView(frame: .zero)
    let contentMask = CAShapeLayer()
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

        contentHolder.wantsLayer = true
        contentMask.fillColor = NSColor.black.cgColor
        contentHolder.layer?.mask = contentMask
        content.wantsLayer = true
        content.autoresizingMask = []
        contentHolder.addSubview(content)
        bodyRoot.addSubview(contentHolder)

        let yUp = !(bodyRoot.layer?.isGeometryFlipped ?? false)
        rimGradient.colors = [
            NSColor.white.withAlphaComponent(0.0).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
            NSColor.white.withAlphaComponent(0.07).cgColor,
            NSColor.white.withAlphaComponent(0.16).cgColor,
        ]
        rimGradient.locations = [0.0, 0.12, 0.42, 1.0]
        rimGradient.startPoint = CGPoint(x: 0.5, y: yUp ? 1.0 : 0.0)
        rimGradient.endPoint = CGPoint(x: 0.5, y: yUp ? 0.0 : 1.0)
        rimMask.fillColor = nil
        rimMask.strokeColor = NSColor.white.cgColor
        rimMask.lineWidth = 1.0
        rimGradient.mask = rimMask
        bodyRoot.layer?.addSublayer(rimGradient)

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

    /// Logical 360 pt body rectangle on screen (excluding top fillet ears).
    var logicalPanelRect: NSRect {
        NSRect(x: placement.centerX - PanelMetrics.width / 2, y: screenFrame.maxY - height,
               width: PanelMetrics.width, height: height)
    }
    /// Body window rectangle widened by `earRadius` on both sides so top concave ears are never clipped.
    var bodyWindowRect: NSRect {
        logicalPanelRect.insetBy(dx: -PanelMetrics.earRadius, dy: 0)
    }
    /// Panel rectangle in the shadow window's coordinates.
    var shadowLocal: CGRect { CGRect(x: PanelMetrics.shadowSide, y: PanelMetrics.shadowBottom, width: PanelMetrics.width, height: height) }
    var bodyLocal: CGRect { CGRect(x: PanelMetrics.earRadius, y: 0, width: PanelMetrics.width, height: height) }
    var rimLocal: CGRect { bodyLocal.insetBy(dx: 0.5, dy: 0.5) }
    var contentLocal: CGRect { CGRect(x: 0, y: 0, width: PanelMetrics.width, height: height) }

    /// Start outline of the grow animation, in the given local rectangle.
    func startPath(in local: CGRect) -> CGPath {
        let w = placement.notchWidth ?? PanelMetrics.flatStartWidth
        let h = placement.hasNotch ? placement.topRow : max(4, (height * 0.03).rounded())
        let r = CGRect(x: local.midX - w / 2, y: local.maxY - h, width: w, height: h)
        let startEar = placement.hasNotch ? PanelMetrics.startEarRadius : 2
        return PanelPath.make(r, radius: min(PanelMetrics.notchRadius, h / 2), ear: startEar, yUp: true)
    }
    func finalPath(in local: CGRect) -> CGPath { PanelPath.make(local, radius: PanelMetrics.radius, yUp: true) }

    /// Top-center anchored scale (0.86) + upward notch offset (10 pt) so content blooms out of and sucks back into the notch.
    func collapsedContentTransform() -> CATransform3D {
        let s: CGFloat = 0.86
        let w = PanelMetrics.width
        let h = height
        let yUp = !(contentHolder.layer?.isGeometryFlipped ?? false)
        let tx = (1 - s) * (w / 2)
        let ty = yUp ? ((1 - s) * h + 10) : -10
        return CATransform3DConcat(CATransform3DMakeScale(s, s, 1), CATransform3DMakeTranslation(tx, ty, 0))
    }

    /// Frames and final outlines, no animation.
    func layout() {
        let lpr = logicalPanelRect
        let bwr = bodyWindowRect
        body.setFrame(bwr, display: false)
        shadow.setFrame(NSRect(x: lpr.minX - PanelMetrics.shadowSide, y: lpr.minY - PanelMetrics.shadowBottom,
                               width: lpr.width + 2 * PanelMetrics.shadowSide, height: lpr.height + PanelMetrics.shadowBottom), display: false)
        contentHolder.frame = bodyLocal
        content.frame = contentLocal
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let bodyBounds = CGRect(origin: .zero, size: bwr.size)
        bodyShape.frame = bodyBounds
        bodyShape.path = finalPath(in: bodyLocal)
        rimGradient.frame = bodyBounds
        rimMask.frame = bodyBounds
        rimMask.path = finalPath(in: rimLocal)
        contentMask.frame = contentLocal
        contentMask.path = finalPath(in: contentLocal)
        shadowShape.frame = CGRect(origin: .zero, size: shadow.frame.size)
        let p = finalPath(in: shadowLocal)
        shadowShape.path = p; shadowShape.shadowPath = p
        CATransaction.commit()
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
    var onUrgent: () -> Void = {}

    private var model: PreBreakModel?
    private var panel: OpenPanel?
    private var retiring: OpenPanel?
    private var generation = 0
    private var pill: PreBreakPanel?
    private var pillTimer: Timer?
    private var pillMonitors: [Any] = []
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
        if s.showPill {
            if pill == nil { showPill() } else { follow() }
        } else {
            hidePill()
        }
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
                        urgent: { [weak self] in self?.onUrgent() },
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
        let curve = CAMediaTimingFunction(controlPoints: 0.28, 1.22, 0.5, 1)
        func anim(_ key: String, from: CGPath, to: CGPath) -> CABasicAnimation {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from; a.toValue = to; a.duration = 0.42; a.timingFunction = curve
            return a
        }
        let bodyFinal = p.finalPath(in: p.bodyLocal)
        let shadowFinal = p.finalPath(in: p.shadowLocal)
        let rimFinal = p.finalPath(in: p.rimLocal)
        let contentFinal = p.finalPath(in: p.contentLocal)

        CATransaction.begin()
        p.bodyShape.add(anim("path", from: p.startPath(in: p.bodyLocal), to: bodyFinal), forKey: "move")
        p.shadowShape.add(anim("path", from: p.startPath(in: p.shadowLocal), to: shadowFinal), forKey: "move")
        p.shadowShape.add(anim("shadowPath", from: p.startPath(in: p.shadowLocal), to: shadowFinal), forKey: "moveShadow")
        p.rimMask.add(anim("path", from: p.startPath(in: p.rimLocal), to: rimFinal), forKey: "move")
        p.contentMask.add(anim("path", from: p.startPath(in: p.contentLocal), to: contentFinal), forKey: "move")

        let rimFade = CABasicAnimation(keyPath: "opacity")
        rimFade.fromValue = 0; rimFade.toValue = 1; rimFade.duration = 0.30
        rimFade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        p.rimGradient.add(rimFade, forKey: "fade")

        let contentMove = CABasicAnimation(keyPath: "transform")
        contentMove.fromValue = NSValue(caTransform3D: p.collapsedContentTransform())
        contentMove.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        contentMove.duration = 0.40
        contentMove.timingFunction = curve
        p.contentHolder.layer?.add(contentMove, forKey: "bloom")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.22
        fade.beginTime = CACurrentMediaTime() + 0.03; fade.fillMode = .backwards
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        p.contentHolder.layer?.add(fade, forKey: "fade")
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
        let finish: @Sendable () -> Void = { [weak self] in
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
            a.fromValue = from; a.toValue = to; a.duration = 0.26; a.timingFunction = curve
            layer.add(a, forKey: "move" + key)
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock(finish)
        retract(p.bodyShape, "path", p.startPath(in: p.bodyLocal))
        retract(p.shadowShape, "path", p.startPath(in: p.shadowLocal))
        retract(p.shadowShape, "shadowPath", p.startPath(in: p.shadowLocal))
        retract(p.rimMask, "path", p.startPath(in: p.rimLocal))
        retract(p.contentMask, "path", p.startPath(in: p.contentLocal))

        let rimFrom = p.rimGradient.presentation()?.opacity ?? 1
        p.rimGradient.opacity = 0
        let rimOut = CABasicAnimation(keyPath: "opacity")
        rimOut.fromValue = rimFrom; rimOut.toValue = 0; rimOut.duration = 0.16
        rimOut.timingFunction = CAMediaTimingFunction(name: .easeIn)
        p.rimGradient.add(rimOut, forKey: "fadeOut")

        let fromTransform = p.contentHolder.layer?.presentation()?.transform ?? CATransform3DIdentity
        let toTransform = p.collapsedContentTransform()
        p.contentHolder.layer?.transform = toTransform
        let contentRetract = CABasicAnimation(keyPath: "transform")
        contentRetract.fromValue = NSValue(caTransform3D: fromTransform)
        contentRetract.toValue = NSValue(caTransform3D: toTransform)
        contentRetract.duration = 0.24
        contentRetract.timingFunction = curve
        p.contentHolder.layer?.add(contentRetract, forKey: "retract")

        let from = p.contentHolder.layer?.presentation()?.opacity ?? 1
        p.contentHolder.layer?.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from; fade.toValue = 0; fade.duration = 0.15
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        p.contentHolder.layer?.add(fade, forKey: "fadeOut")
        CATransaction.commit()
    }

    /// The content can change height while the panel is up (the hard line appears): follow it, no animation.
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
            .padding(PreBreakController.pillInset)
            .environment(\.locale, AppLanguage.current.locale))
        let p = PreBreakPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        Self.configure(p)
        p.hasShadow = true                   // the system shadow follows the capsule's alpha
        #if DEBUG
        switch ProcessInfo.processInfo.environment["PAUSA_APPEARANCE"] {
        case "dark": p.appearance = NSAppearance(named: .darkAqua)
        case "light": p.appearance = NSAppearance(named: .aqua)
        default: break
        }
        #endif
        p.ignoresMouseEvents = true          // clicks fall through to the app below
        p.contentView = host
        pill = p
        follow()
        p.orderFrontRegardless()
        // Follow every pointer event (the system's own rate, 120 Hz on ProMotion); the timer only backstops a
        // pointer that moved without an event, such as a space switch or a display change. Neither monitor
        // needs a permission: mouse-moved events carry no key data.
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        pillMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: moves) { [weak self] _ in MainActor.assumeIsolated { self?.follow() } },
            NSEvent.addLocalMonitorForEvents(matching: moves) { [weak self] e in MainActor.assumeIsolated { self?.follow() }; return e },
        ].compactMap { $0 }
        let t = Timer(timeInterval: 1.0 / 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        RunLoop.main.add(t, forMode: .common)
        pillTimer = t
    }

    private func hidePill() {
        pillTimer?.invalidate(); pillTimer = nil
        pillMonitors.forEach { NSEvent.removeMonitor($0) }; pillMonitors = []
        pill?.orderOut(nil)
        pill = nil
    }

    /// (+16, −20) from the pointer; flips left / above near an edge; always inside the pointer's screen.
    private func follow() {
        guard let p = pill, let host = p.contentView else { return }
        let size = host.fittingSize
        let m = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) else { return }
        let f = Self.pillFrame(mouse: m, size: size, in: screen.frame)
        if f.size == p.frame.size { p.setFrameOrigin(f.origin) } else { p.setFrame(f, display: true) }   // same size: just move
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
