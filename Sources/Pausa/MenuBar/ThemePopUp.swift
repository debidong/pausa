import AppKit
import SwiftUI

/// 主题 pop-up. AppKit rather than a SwiftUI Picker because 我的照片… must act on every pick, including
/// re-picking it while it is already the theme (spec O1: a Picker binding only reports changes, and its
/// menu can't be driven offscreen to prove otherwise). NSPopUpButton sends its action for every item
/// chosen, current or not. The pop-up always shows `selection`: a pick that doesn't change the theme
/// (我的照片… cancelled or failed) snaps back.
struct ThemePopUp: NSViewRepresentable {
    var selection: ThemeChoice
    var onPick: (ThemeChoice) -> Void

    /// Menu order (spec §3.1): the four scenes, 随机, then 模糊桌面 and 我的照片….
    static let layout: [ThemeChoice?] = ThemeChoice.scenes + [nil, .random, nil, .softDesktop, .photo]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FittedPopUp {
        let b = FittedPopUp(frame: .zero, pullsDown: false)
        b.target = context.coordinator
        b.action = #selector(Coordinator.picked(_:))
        b.setContentHuggingPriority(.required, for: .horizontal)
        fill(b)
        return b
    }

    func updateNSView(_ b: FittedPopUp, context: Context) {
        context.coordinator.parent = self
        fill(b)   // titles follow the app language
    }

    /// Selects `selection`, rebuilding the items first only when their titles changed (language switch),
    /// so an open menu is never swapped out from under the user.
    func fill(_ b: NSPopUpButton) {
        let titles = Self.layout.map { $0?.title }
        if b.itemArray.map({ $0.isSeparatorItem ? nil : $0.title }) != titles { rebuild(b) }
        b.select(b.itemArray.first { $0.representedObject as? String == selection.rawValue })
        b.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FittedPopUp, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    /// As wide as the shown title, like the Form's SwiftUI pickers (an NSPopUpButton is otherwise as wide
    /// as its longest item, which leaves a gap between a short title and the chevrons).
    final class FittedPopUp: NSPopUpButton {
        /// NSPopUpButtonCell leaves 3 pt more between title and chevrons than SwiftUI's pickers do.
        static let trim: CGFloat = 3
        /// …and is 2 pt taller, which would make its Form row 2 pt taller than the others.
        static let trimHeight: CGFloat = 4
        override var intrinsicContentSize: NSSize {
            var size = super.intrinsicContentSize
            guard let shown = selectedItem, let font else { return size }
            func width(_ t: String) -> CGFloat { ceil((t as NSString).size(withAttributes: [.font: font]).width) }
            let widest = itemArray.filter { !$0.isSeparatorItem }.map { width($0.title) }.max() ?? 0
            size.width -= widest - width(shown.title) + Self.trim
            size.height -= Self.trimHeight
            return size
        }
    }

    private func rebuild(_ b: NSPopUpButton) {
        let menu = NSMenu()
        for t in Self.layout {
            guard let t else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: t.title, action: nil, keyEquivalent: "")
            item.representedObject = t.rawValue
            menu.addItem(item)
        }
        b.menu = menu
    }

    final class Coordinator: NSObject {
        var parent: ThemePopUp
        init(_ parent: ThemePopUp) { self.parent = parent }
        @MainActor @objc func picked(_ sender: NSPopUpButton) {
            guard let raw = sender.selectedItem?.representedObject as? String, let t = ThemeChoice(rawValue: raw) else { return }
            parent.onPick(t)
            // 我的照片… only opens the panel: show the current theme until an import changes it.
            if t == .photo { parent.fill(sender) }
        }
    }
}
