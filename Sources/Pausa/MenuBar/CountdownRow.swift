import AppKit

/// A menu row that reads "Short break in 7:53" and, when highlighted (hover or arrow keys),
/// reads "Short Break Now"; clicking starts that break. Drawn to match native menu items.
@MainActor
final class CountdownRowView: NSView {
    static let height: CGFloat = 22
    static let leading: CGFloat = 14       // text inset, same as native items (state column hidden)
    static let trailing: CGFloat = 14
    static let highlightInset: CGFloat = 5 // rounded selection inset, macOS 11+ style
    static var font: NSFont { NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular) }

    var idleText = "" { didSet { if idleText != oldValue { needsDisplay = true } } }
    var actionText = "" { didSet { if actionText != oldValue { needsDisplay = true } } }
    var enabled = true { didSet { if enabled != oldValue { needsDisplay = true } } }
    var forceHighlight: Bool?   // offscreen rendering only
    var onClick: (() -> Void)?

    private let selection = NSVisualEffectView()
    private let label = LabelView()   // above the selection material (subviews paint over draw(_:))

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
        selection.material = .selection
        selection.state = .active
        selection.isEmphasized = true
        selection.blendingMode = .behindWindow
        selection.wantsLayer = true
        selection.layer?.cornerRadius = 5
        selection.layer?.masksToBounds = true
        selection.isHidden = true
        selection.autoresizingMask = [.width, .height]
        addSubview(selection)
        label.autoresizingMask = [.width, .height]
        label.frame = bounds
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var highlighted: Bool { enabled && (forceHighlight ?? enclosingMenuItem?.isHighlighted ?? false) }

    override func draw(_ dirtyRect: NSRect) {
        let hi = highlighted
        selection.frame = bounds.insetBy(dx: Self.highlightInset, dy: 0)
        selection.isHidden = !hi
        let color: NSColor = !enabled ? .disabledControlTextColor : hi ? .selectedMenuItemTextColor : .labelColor
        label.frame = bounds
        label.text = NSAttributedString(string: hi ? actionText : idleText,
                                        attributes: [.font: Self.font, .foregroundColor: color])
        label.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard enabled else { return }
        let menu = enclosingMenuItem?.menu
        menu?.cancelTracking()
        let f = onClick
        DispatchQueue.main.async { f?() }   // after tracking ends, so the overlay isn't fighting the menu
    }

    /// Width that fits every string the row or the menu may show, so the menu never resizes as digits tick.
    static func width(for strings: [String]) -> CGFloat {
        let w = strings.map { NSAttributedString(string: $0, attributes: [.font: font]).size().width }.max() ?? 0
        return ceil(w) + leading + trailing
    }
}

private final class LabelView: NSView {
    var text = NSAttributedString()
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the row
    override func draw(_ dirtyRect: NSRect) {
        let h = text.size().height
        text.draw(at: NSPoint(x: CountdownRowView.leading, y: ((bounds.height - h) / 2).rounded()))
    }
}
