import AppKit
import CoreText
import SwiftUI
import PausaCore
import Combine
import os

/// Status item: countdown to the next break, text only.
/// Click opens a SwiftUI popover (MenuPopoverView); settings / pause / quit live in its gear menu.
@MainActor
final class MenuBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let app: AppController
    private let popover = NSPopover()
    private let model = PopoverModel()
    private var lastTitle = ""
    private var lastIconKey = ""
    var settingsWindow: NSWindow?
    private var langSub: AnyCancellable?
    private var dockSub: AnyCancellable?
    private var themeSub: AnyCancellable?
    private var updateSub: AnyCancellable?

    init(app: AppController) {
        self.app = app
        super.init()
        Self.shared = self
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        rebuildContent()
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.setAccessibilityLabel(appName)
        app.onChange = { [weak self] in self?.refresh() }
        langSub = app.settings.$language.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.rebuildContent()
            self?.refresh()
            self?.settingsTabs?.relabel()
            self?.settingsWindow?.title = appName
        }
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        themeSub = app.settings.$theme.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.rebuildContent()   // popover takes the new accent at once
            DispatchQueue.main.async { self?.lastIconKey = ""; self?.refresh() }   // and the ring
        }
        dockSub = app.settings.$showInDock.receive(on: RunLoop.main).sink { [weak self] on in
            self?.applyDock(on)
        }
        updateSub = UpdateModel.shared.$phase.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    private var actions: PopoverActions {
        PopoverActions(
            breakNow: { [weak self] in self?.run { $0.app.breakNow($0.app.scheduler.next.kind) } },
            postpone: { [weak self] secs in self?.app.postpone(by: secs) },
            togglePause: { [weak self] in self?.run { $0.togglePause() } },
            settings: { [weak self] in self?.run { $0.openSettings() } },
            about: { [weak self] in self?.run { _ in Self.showAbout() } },
            installUpdate: { [weak self] in self?.run { _ in UpdateModel.shared.install() } },
            quit: { NSApp.terminate(nil) })
    }

    /// Close the popover first so an overlay or window doesn't fight it.
    private func run(_ f: @escaping (MenuBarController) -> Void) {
        popover.performClose(nil)
        DispatchQueue.main.async { [weak self] in if let s = self { f(s) } }
    }

    private func rebuildContent() {
        let host = NSHostingController(rootView: MenuPopoverView(model: model, actions: actions).pausaTheme(app.settings.theme))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
    }

    @objc func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// Live switch between menu-bar-only (.accessory) and Dock app (.regular); no restart.
    private func applyDock(_ on: Bool) {
        let policy: NSApplication.ActivationPolicy = on ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if on { app.settings.icon.apply() }   // the Dock tile shows the chosen icon
        if let w = settingsWindow, w.isVisible {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                w.center()
                w.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// First launch only: tells the user Pausa is running and when the next break is.
    /// Icon visible: a popover under it, arrow pointing at it. Icon hidden (notch, menu bar manager):
    /// the same text in a panel at the top right, just under the menu bar, no arrow. 8 s, click closes.
    /// An item pushed behind the notch still reports itself visible and on screen.
    static func underNotch(_ f: NSRect, on s: NSScreen) -> Bool {
        guard #available(macOS 12, *) else { return false }
        return underNotch(f, leftArea: s.auxiliaryTopLeftArea, rightArea: s.auxiliaryTopRightArea)
    }

    static func underNotch(_ f: NSRect, leftArea l: NSRect?, rightArea r: NSRect?) -> Bool {
        guard let l, let r else { return false }
        return f.maxX > l.maxX && f.minX < r.minX
    }

    static let hiddenHint = "menu.iconHidden"

    /// The icon can be seen: its window is visible, on a screen (menu bar managers move it off screen), and not behind the notch.
    var iconVisible: Bool {
        guard let w = item.button?.window, w.occlusionState.contains(.visible),
              let s = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: w.frame.midX, y: w.frame.midY)) })
        else { return false }
        return !Self.underNotch(w.frame, on: s)
    }

    func showWelcomeOnce() {
        let d = PausaDefaults.store
        guard !d.bool(forKey: DefaultsKey.didShowWelcome) else { return }
        d.set(true, forKey: DefaultsKey.didShowWelcome)
        let visible = iconVisible
        let text = visible ? L("menu.welcome", Self.welcomeDuration(app.scheduler.next.remaining))
                           : L(Self.hiddenHint)
        let label = Text(text)
            .environment(\.locale, AppLanguage.current.locale)
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .fixedSize()
        if visible, let button = item.button {
            let pop = NSPopover()
            pop.behavior = .transient   // any click closes it
            pop.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            pop.contentViewController = NSHostingController(rootView: label)
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { pop.performClose(nil) }
            return
        }
        guard let screen = NSScreen.main else { return }
        let host = NSHostingView(rootView: label
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous)))
        let size = host.fittingSize
        let vf = screen.visibleFrame   // top edge = bottom of the menu bar
        let panel = WelcomePanel(contentRect: NSRect(x: vf.maxX - size.width - 12, y: vf.maxY - size.height - 8,
                                                     width: size.width, height: size.height),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .statusBar; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.contentView = host
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { panel.close() }
    }

    /// "20 minutes" / "20 分钟" in the app language (system formatter, never hand-built units).
    static func welcomeDuration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .full; f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        var cal = Calendar.current; cal.locale = AppLanguage.current.locale; f.calendar = cal
        return f.string(from: max(60, (seconds / 60).rounded() * 60)) ?? ""
    }

    /// The popover's values from the live app state.
    static func state(of app: AppController) -> PopoverState {
        let sch = app.scheduler
        let n = sch.next
        var onBreak = false
        if case .onBreak = sch.phase { onBreak = true }
        let auto = app.autoPauseStatus
        let held = app.isPaused || auto != nil || onBreak
        var st = PopoverState()
        st.kind = n.kind
        st.length = n.kind == .long ? sch.config.longLength : sch.config.shortLength
        st.remaining = n.remaining
        st.held = held
        if held {
            st.status = app.statusLine
            if !app.manualPaused, let src = app.currentPauseSource, st.status == src.statusText {
                st.statusAppID = src.bundleID; st.statusAppName = src.displayName
            }
        }
        st.canBreak = !onBreak
        st.can5 = !held && sch.canPostpone(by: AppController.postponeShort)
        st.can15 = !held && sch.canPostpone(by: AppController.postponeLong)
        st.hardLine = !held && sch.atHardLine && !st.can5
        st.show15 = sch.postponeBudget(n.kind) >= AppController.postponeLong
        st.manualPaused = app.manualPaused
        st.autoPaused = app.isPaused && !app.manualPaused
        st.update = UpdateModel.shared.readyVersion
        let canInstall = !app.blocksRelaunch
        st.canInstall = canInstall
        UpdateModel.shared.canInstall = canInstall
        return st
    }

    private func refresh() {
        let st = Self.state(of: app)
        if model.state != st { model.state = st }
        item.button?.toolTip = app.statusLine

        if app.settings.menuBarDisplay == .progressRing {
            // Original (pre-round-4) ring: pie fills toward the next break, dashed when paused.
            if !lastTitle.isEmpty { lastTitle = ""; item.button?.title = "" }
            let paused = app.isPaused
            let warning: Bool = switch app.scheduler.effectiveMode {
            case .warning, .deferred: true
            default: false
            }
            let step = ringStep(fraction: app.scheduler.next.fraction, paused: paused)
            let key = "\(paused)-\(warning)-\(step)-\(app.settings.theme.rawValue)"
            guard key != lastIconKey else { return }
            lastIconKey = key
            item.button?.image = Self.icon(fraction: Double(step) / 24, paused: paused, warning: warning)
            return
        }
        if !lastIconKey.isEmpty { lastIconKey = ""; item.button?.image = nil }
        let title = Self.menuTitle(app.scheduler.next.remaining)
        guard title != lastTitle else { return }
        lastTitle = title
        item.button?.title = title
    }

    static func icon(fraction: Double, paused: Bool, warning: Bool) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            let r = rect.insetBy(dx: 2, dy: 2)
            NSColor.black.setStroke()
            let ring = NSBezierPath(ovalIn: r)
            ring.lineWidth = 1.5
            if paused {
                let dash: [CGFloat] = [2, 2]
                ring.setLineDash(dash, count: 2, phase: 0)
            }
            ring.stroke()
            guard !paused, fraction > 0 else { return true }
            let c = NSPoint(x: r.midX, y: r.midY)
            let p = NSBezierPath()
            p.move(to: c)
            p.appendArc(withCenter: c, radius: r.width / 2 - 1.5, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            p.close()
            NSColor.black.setFill()
            p.fill()
            return true
        }
        // Template so it follows light/dark menu bar; warning uses the system accent color.
        img.isTemplate = !warning
        if warning {
            let tinted = NSImage(size: size, flipped: false) { rect in
                img.draw(in: rect)
                Settings.shared.theme.accentNS.set()   // the theme accent, the one colour source
                rect.fill(using: .sourceAtop)
                return true
            }
            return tinted
        }
        return img
    }

    static func menuTitle(_ remaining: Double) -> String { AppController.clock(remaining) }

    // MARK: actions

    private func togglePause() { app.manualPaused ? app.resume() : app.pause() }

    /// "关于 Pausa": the About page of the Settings window (no separate panel).
    static weak var shared: MenuBarController?
    static func showAbout() { shared?.showSettings(page: .about) }

    @objc func openSettings() { IconHint.shared.hidden = false; showSettings(page: nil) }

    /// Reopen (Dock click, launching Pausa again): Settings, with a note on top when the icon can't be seen.
    func reopen() {
        IconHint.shared.hidden = !iconVisible
        showSettings(page: nil)
    }

    func showSettings(page: SettingsPage?) {
        if settingsWindow == nil {
            let (w, tabs) = SettingsTabsController.makeWindow(settings: app.settings,
                                                              onPreview: { [weak app] in app?.previewLong() })
            settingsWindow = w
            settingsTabs = tabs
        }
        if let p = page { settingsTabs?.select(p) }
        StatsModel.shared.showToday()   // 统计 always opens on today, with fresh numbers
        settingsTabs?.fitHeight(to: SettingsNav.shared.page)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsTabs?.logFrame("open")
    }
    private var settingsTabs: SettingsTabsController?
}

enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case breaks, general, stats, about
    var id: String { rawValue }
    /// Saved tab id -> page; the removed 外观 tab (round 7) now lives on 通用.
    init?(saved: String) {
        if saved == "appearance" { self = .general } else { self.init(rawValue: saved) }
    }
    var title: String {
        switch self {
        case .breaks: return L("settings.tab.breaks"); case .general: return L("settings.tab.general")
        case .stats: return L("settings.tab.stats"); case .about: return L("settings.tab.about")
        }
    }
    var symbol: String {
        switch self {
        case .breaks: return "cup.and.saucer"; case .general: return "gearshape"
        case .stats: return "chart.bar"; case .about: return "info.circle"
        }
    }
}

/// Set on reopen: the menu bar icon can't be seen, so Settings says why.
final class IconHint: ObservableObject {
    static let shared = IconHint()
    @Published var hidden = false
}

/// Last-viewed tab (DefaultsKey.settingsTab); the first tab on first open.
final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var page: SettingsPage = SettingsPage(saved: PausaDefaults.store.string(forKey: DefaultsKey.settingsTab) ?? "") ?? .breaks {
        didSet { PausaDefaults.store.set(page.rawValue, forKey: DefaultsKey.settingsTab) }
    }
}

/// One settings page: a plain grouped Form (Steve), localized and themed.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    let page: SettingsPage
    var onPreview: () -> Void = {}
    /// Debug renders only (`--render-settings … --theme ocean`): never persisted.
    static var themeOverride: ThemeChoice?
    /// Minimum content width (round 7c rev 2: the window starts 500 pt wide and can grow).
    nonisolated static let width: CGFloat = 500

    @ObservedObject private var hint = IconHint.shared

    var body: some View {
        VStack(spacing: 0) {
            if hint.hidden {
                Text(L(MenuBarController.hiddenHint))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.top, 12)
            }
            Group {
            switch page {
            case .breaks: BreaksPage(settings: settings)
            case .general: GeneralPage(settings: settings, onPreview: onPreview)
            case .stats: StatsPage()
            case .about: AboutPage(settings: settings)
            }
            }
        }
        .id(settings.language)
        .environment(\.locale, AppLanguage.current.locale)
        // Round 7c: every control colour comes from the selected theme (one source, set here).
        .pausaTheme(Self.themeOverride ?? settings.theme)
        // Fill the page area, top-aligned. No minHeight here: 420 is the window FRAME minimum, the page area
        // under the tab bar is ~340 pt, and a taller SwiftUI minimum overflowed and was centred, pushing the
        // first section title under the tab bar. The Form scrolls inside whatever height it gets.
        .frame(minWidth: Self.width, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Height of the whole page content (Form without scrolling), measured offscreen.
    @MainActor static func contentHeight(_ settings: Settings, _ page: SettingsPage, width: CGFloat = width) -> CGFloat {
        let v = NSHostingView(rootView: SettingsView(settings: settings, page: page).scrollDisabled(true)
            .frame(width: max(width, Self.width)).fixedSize(horizontal: false, vertical: true))
        return ceil(v.fittingSize.height)
    }
}

/// Native preferences window (like Safari's settings): toolbar tabs with the label under each icon.
/// Round 7c rev 2: first open 500 x 809 pt (whole frame, capped at the visible height), centred. Resizable, minimum 500 x 420, no maximum.
/// Stats items 28/33 (Steve, 2026-10-19): each tab sets the window height to its content (grow and shrink,
/// animated, top edge fixed, width kept); pages scroll only when the screen is shorter. Position and width
/// are kept under the autosave key (the old one is never read). Title always "Pausa".
@MainActor
final class SettingsTabsController: NSTabViewController {
    /// Round 7c (j, rev 2): portrait golden ratio 500 × 809, capped at the screen's visible height.
    static let goldenSize = NSSize(width: 500, height: 809)
    static let minimumSize = NSSize(width: 500, height: 420)
    /// Steve (2026-10-19): the tallest a Settings window gets from a page; taller pages scroll inside.
    static let maxFittedHeight: CGFloat = 880
    static func initialSize(for screen: NSScreen?) -> NSSize {
        let h = screen?.visibleFrame.height ?? goldenSize.height
        return NSSize(width: goldenSize.width, height: max(minimumSize.height, min(goldenSize.height, h)))
    }
    nonisolated static let autosave = "PausaSettingsFrame.v3"
    static let legacyAutosaves = ["PausaSettingsWindow", "PausaSettingsFrame.v2"]
    private let settings: Settings
    private var resizeObserver: Any?
    private var liveResizeObserver: Any?

    /// Builds the window without showing it (also used by the self-test with its own autosave key).
    static func makeWindow(settings: Settings, onPreview: @escaping () -> Void,
                           autosave: String = autosave) -> (NSWindow, SettingsTabsController) {
        for k in legacyAutosaves { NSWindow.removeFrame(usingName: k) }   // never restore old frames
        let tabs = SettingsTabsController(settings: settings, onPreview: onPreview)
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.toolbarStyle = .preference
        w.title = appName
        w.isReleasedWhenClosed = false
        pinMinimum(w)
        w.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let restored = w.setFrameUsingName(autosave)
        if !restored {
            w.setFrame(NSRect(origin: w.frame.origin, size: initialSize(for: w.screen ?? NSScreen.main)), display: false)
        }
        tabs.adoptWindowSize()
        tabs.fitHeight(to: SettingsNav.shared.page)   // the selected tab's height (saved position: top edge kept)
        // While 统计 is the selected tab, its content height can change (empty -> data, 清除, refresh).
        StatsModel.shared.onContentChange = { [weak tabs] in
            guard let tabs, SettingsNav.shared.page == .stats, tabs.view.window != nil else { return }
            tabs.fitHeight(to: .stats)   // no-op unless the height really changed (no per-minute jitter)
        }
        if !restored { w.center() }
        w.setFrameAutosaveName(autosave)
        tabs.liveResizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification,
                                                                         object: w, queue: .main) { [weak tabs] _ in
            MainActor.assumeIsolated { tabs?.logFrame("drag") }   // a user drag finished
        }
        tabs.resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: w,
                                                                     queue: .main) { [weak tabs] _ in
            MainActor.assumeIsolated { tabs?.adoptWindowSize() }
        }
        return (w, tabs)
    }

    init(settings: Settings, onPreview: @escaping () -> Void) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = []   // no size change and no system crossfade; we fade the new page in
        canPropagateSelectedChildViewControllerTitle = false
        for p in SettingsPage.allCases {
            let host = NSHostingController(rootView: SettingsView(settings: settings, page: p, onPreview: onPreview))
            host.sizingOptions = []   // SwiftUI never sizes the window
            let item = NSTabViewItem(viewController: host)
            item.identifier = p.rawValue
            item.label = p.title
            item.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.title)
            addTabViewItem(item)
        }
        selectedTabViewItemIndex = SettingsPage.allCases.firstIndex(of: SettingsNav.shared.page) ?? 0
    }
    required init?(coder: NSCoder) { fatalError() }

    func select(_ p: SettingsPage) { selectedTabViewItemIndex = SettingsPage.allCases.firstIndex(of: p) ?? 0 }

    func relabel() {
        for (item, p) in zip(tabViewItems, SettingsPage.allCases) { item.label = p.title }
        view.window?.title = appName
    }

    /// Every tab's preferred size = the window's current content size, so the tab controller never
    /// resizes the window on a switch.
    func adoptWindowSize() {
        guard let w = view.window, let cv = w.contentView else { return }
        _ = cv
        // Round 7c rev 2 root cause: setting each tab's preferredContentSize here made AppKit pin the page
        // views with REQUIRED width/height constraints, so a mouse drag could not resize the window
        // (setFrame still could). Tabs keep a zero preferredContentSize; tab switches restore the frame.
        for item in tabViewItems where item.viewController?.preferredContentSize != .zero {
            item.viewController?.preferredContentSize = .zero
        }
        Self.pinMinimum(w)
    }

    /// Minimum whole frame 500 × 420. Set as a content minimum (frame minus title bar and toolbar), because
    /// AppKit reads minSize against the content area under a preference toolbar and NSTabViewController
    /// rewrites it from preferredContentSize.
    static func pinMinimum(_ w: NSWindow) {
        let c = w.contentRect(forFrameRect: NSRect(origin: .zero, size: minimumSize)).size
        if w.contentMinSize != c { w.contentMinSize = c }
    }
    static func minimumFrame(_ w: NSWindow) -> NSSize {
        w.frameRect(forContentRect: NSRect(origin: .zero, size: w.contentMinSize)).size
    }

    #if DEBUG
    /// Self-test only: pretend the screen's visible frame is this tall (the short-screen case).
    static var visibleHeightOverride: CGFloat?
    #endif
    /// Stats spec items 28 / 33 (Steve): like macOS's own Settings windows, every tab sets the window's
    /// height to min(content, `maxFittedHeight`, screen visible height), growing AND shrinking, animated
    /// with the system default. Width is kept and the top edge stays put; a capped page scrolls.
    func fitHeight(to page: SettingsPage) {
        guard let w = view.window else { return }
        let content = SettingsView.contentHeight(settings, page, width: w.contentLayoutRect.width) + 1
        let chrome = w.frame.height - w.contentLayoutRect.height   // title bar + toolbar
        let screen = (w.screen ?? NSScreen.main)?.visibleFrame
        var capH = screen?.height ?? .greatestFiniteMagnitude, faked = false
        #if DEBUG
        if let o = Self.visibleHeightOverride { capH = o; faked = true }
        #endif
        var f = w.frame
        f.size.height = max(Self.minimumFrame(w).height, min(chrome + content, Self.maxFittedHeight, capH))
        f.origin.y = w.frame.maxY - f.height
        if let screen, !faked, f.minY < screen.minY { f.origin.y = screen.minY }   // only when the top can't stay
        guard abs(f.height - w.frame.height) > 0.5 || f.origin != w.frame.origin else { return }
        w.setFrame(f, display: true, animate: w.isVisible)   // a never-shown window resizes at once
    }

    private var frameBeforeSwitch: NSRect?
    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        adoptWindowSize()
        frameBeforeSwitch = view.window?.frame
        super.tabView(tabView, willSelect: tabViewItem)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String, let p = SettingsPage(rawValue: id) { SettingsNav.shared.page = p }
        guard let w = view.window, let vc = tabViewItem?.viewController else { return }
        if let f = frameBeforeSwitch, f != w.frame { w.setFrame(f, display: true) }   // undo any AppKit resize first
        frameBeforeSwitch = nil
        fitHeight(to: SettingsNav.shared.page)
        w.title = appName
        Self.scrollToTop(vc.view)
        // Only the new page's content fades in (0.25 s).
        vc.view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            vc.view.animator().alphaValue = 1
        }
        if w.isVisible { logFrame("tab") }
    }

    /// Every tab switch starts at the top of the page.
    static func scrollToTop(_ v: NSView) {
        if let sv = v as? NSScrollView, let doc = sv.documentView {
            let y = doc.isFlipped ? 0 : max(0, doc.bounds.height - sv.contentView.bounds.height)
            sv.contentView.scroll(to: NSPoint(x: 0, y: y))
            sv.reflectScrolledClipView(sv.contentView)
        }
        v.subviews.forEach(scrollToTop)
    }

    /// Diagnostics in debug builds only: emit tab/frame layout to unified logging (no unbounded disk files).
    func logFrame(_ event: String) {
        #if DEBUG
        guard let w = view.window, !Settings.dryRun else { return }
        let f = w.frame, c = w.contentView?.frame.size ?? .zero
        Logger(subsystem: "app.pausa", category: "settings").debug(
            "\(event, privacy: .public) tab=\(SettingsNav.shared.page.rawValue, privacy: .public) frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) content=\(Int(c.width))x\(Int(c.height))"
        )
        #endif
    }
}

/// Every Settings and popover control takes the theme accent from the root (.pausaTheme); no control sets its own.
/// Section footer on the shared left edge. macOS draws grouped-form footers trailing and at the
/// box edge; measured renders put row names and headers 10 pt further in, so the footer matches them.
struct FormFooter: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        // Steve: system default footer position, no custom padding (real-Mac check by Bowen).
        Text(text).multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// 休息 = 休息节奏 + 提醒时段 + 自动暂停: when to break, then when not to.
struct BreaksPage: View {
    @ObservedObject var settings: Settings
    typealias S = Settings

    /// Changing the interval never leaves the count greyed out: it drops to the largest value
    /// Config.allows for the new interval (no alert). Same clamp as Settings uses on load.
    private var interval: Binding<Int> {
        Binding(get: { settings.shortEveryMin }, set: { v in
            settings.shortEveryMin = v
            settings.shortsBeforeLong = S.clampedCount(settings.shortsBeforeLong, everyMin: v, line: settings.hardLineMinutes)
        })
    }
    /// An interval is offered only if even the smallest count keeps the long break within the hard line.
    static func intervalDisabled(_ m: Int) -> Bool { !S.intervalAllowed(m, line: S.shared.hardLineMinutes) }

    var body: some View {
        // Steve: grouped Form, one control per row; the rhythm sentence is the one exception.
        Form {
            Section {
                Picker(L("breaks.preset"), selection: Binding(get: { settings.preset }, set: { settings.preset = $0 })) {
                    ForEach(S.Preset.allCases) { Text($0.title).tag($0).disabled(!settings.allows($0)) }
                }
                RhythmSentence(settings: settings, interval: interval)
                // 「长休息最晚间隔」: a line under interval × count is greyed; nothing else changes with it.
                Picker(L("breaks.hardLine"), selection: $settings.hardLineMinutes) {
                    ForEach(Config.hardLineOptions, id: \.self) { v in
                        Text(L("breaks.hardLineOption", v)).tag(v)
                            .disabled(!Config.allows(everyMin: settings.shortEveryMin, count: settings.shortsBeforeLong, line: v))
                    }
                }
            } header: {
                Text(L("breaks.rhythm"))
            }
            Section {
                Picker(L("breaks.shortLength"), selection: $settings.shortLengthSec) {
                    ForEach(S.shortLengthOptions, id: \.self) { v in Text(L("unit.seconds", v)).tag(v) }
                }
                Picker(L("breaks.longLength"), selection: $settings.longLengthMin) {
                    ForEach(S.longLengthOptions, id: \.self) { v in Text(L("unit.minutes", v)).tag(v) }
                }
                Picker(L("breaks.sound"), selection: $settings.breakSound) {
                    ForEach(BreakSound.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Toggle(L("prebreak.setting.card"), isOn: $settings.showPreBreakPanel)
                Toggle(L("prebreak.setting.pill"), isOn: $settings.showPreBreakPill)
            } header: {
                Text(L("prebreak.setting.header"))
            }
            AutoPauseSection(settings: settings)
            ScheduleSection(settings: settings)
        }
        .formStyle(.grouped)
    }
}

/// 「每 [20 分钟] 休息一次，」 / 「短休息 [1] 次后进行一次长休息。」: always two lines (break at the comma),
/// no row label, two compact inline pickers. A line that doesn't fit may break only before its picker;
/// the picker and the words after it stay together.
struct RhythmSentence: View {
    @ObservedObject var settings: Settings
    let interval: Binding<Int>
    typealias S = Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            line(L("rhythm.line1"), Picker("", selection: interval) {
                ForEach(S.shortEveryOptions, id: \.self) { v in Text(L("unit.minutes", v)).tag(v).disabled(BreaksPage.intervalDisabled(v)) }
            })
            line(Plural.pick("rhythm.line2", settings.shortsBeforeLong), Picker("", selection: $settings.shortsBeforeLong) {
                ForEach(S.shortsBeforeLongOptions, id: \.self) { n in
                    Text(verbatim: "\(n)").tag(n).disabled(!Config.allows(everyMin: settings.shortEveryMin, count: n, line: settings.hardLineMinutes))
                }
            })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// template "prefix {1} suffix": [prefix] then [picker + suffix] as one unbreakable unit.
    private func line<P: View>(_ template: String, _ picker: P) -> some View {
        let parts = template.components(separatedBy: "{1}")
        let pre = parts.first ?? "", post = parts.count > 1 ? parts[1] : ""
        // Steve: strings carry no spaces around the picker; a uniform 6 pt gap on both sides.
        let unit = HStack(spacing: 6) {
            picker.labelsHidden().pickerStyle(.menu).fixedSize()
            if !post.isEmpty { Text(post).fixedSize() }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { if !pre.isEmpty { Text(pre).fixedSize() }; unit }
            VStack(alignment: .leading, spacing: 4) { if !pre.isEmpty { Text(pre) }; unit }
        }
    }
}

struct GeneralPage: View {
    @ObservedObject var settings: Settings
    var onPreview: () -> Void = {}
    var body: some View {
        Form {
            Section {
                Toggle(L("general.openAtLogin"), isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }).animation())
                Picker(selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
                } label: {
                    // Globe after the word so every row's label starts at the same x.
                    HStack(spacing: 5) {
                        Text(L("general.language"))
                        Image(systemName: "globe").foregroundStyle(.secondary)
                    }
                }
            }
            AppearanceSection(settings: settings, onPreview: onPreview)
        }
        .formStyle(.grouped)
    }
}

/// The former 外观 tab (round 7): same rows, same order, its own group on 通用.
struct AppearanceSection: View {
    @ObservedObject var settings: Settings
    var onPreview: () -> Void
    var body: some View {
            Section {
                Picker(L("general.menuBarShows"), selection: $settings.menuBarDisplay) {
                    ForEach(MenuBarDisplay.allCases) { Text($0.title).tag($0) }
                }
                IconChooser(selection: $settings.icon)
                Toggle(L("general.showInDock"), isOn: $settings.showInDock.animation())
                Picker(L("appearance.mode"), selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                // 我的照片… never sets the theme itself: it opens the panel (also when already chosen),
                // and only a successful import sets it (PhotoBackground.choose, spec §3.1).
                LabeledContent(L("appearance.theme")) {
                    ThemePopUp(selection: settings.theme) { new in
                        if new == .photo {
                            PhotoBackground.choose(in: NSApp.keyWindow)
                        } else if new == .systemWallpaper {
                            SystemWallpaper.selectFromMenu(in: NSApp.keyWindow, settings: settings)
                        } else {
                            settings.theme = new
                        }
                    }.fixedSize()
                }
                LabeledContent(L("appearance.previewBreak")) {
                    Button(L("common.preview"), action: onPreview)
                }
            } header: {
                Text(L("appearance.title"))
            }
    }
}

struct AboutPage: View {
    @ObservedObject var settings: Settings
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0" }
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        // The card is its section's row background, so it takes exactly the grouped section's frame
        // (same width as the version box); the note is the section footer, outside the box.
        Form {
            Section {
                // The grouped row keeps a 10 pt content inset even with zero listRowInsets; bleed
                // the card over it so it fills the section box exactly (= the version box width).
                AboutCard()
                    .padding(-10)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                Text(L("about.medical"))   // wording pending medical review
                    .font(.system(size: 11))
                    // Not .secondary: measured below 4.5:1 on the window background.
                    .foregroundStyle(scheme == .dark ? Color(white: 0.68) : Color(white: 0.38))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }
            Section {
                UpdateRow(model: .shared, version: version)
            }
        }
        .formStyle(.grouped)
    }
}

/// About top card: watercolor lotus pond (App/about, 1440x600 crops of the day/night art) filling the
/// card, lotus on the left; bottom-right Square Fold brand lockup ("Pausa" linking to official site + "by debidong").
struct AboutCard: View {
    @Environment(\.colorScheme) private var scheme
    static let height: CGFloat = 220
    /// Soft botanical sage-pine so the wordmark blends into the watercolor wash instead of reading as stark black.
    static let inkLight = Color(red: 0x2C / 255, green: 0x45 / 255, blue: 0x38 / 255)   // #2C4538
    static let cream = Color(red: 0xF0 / 255, green: 0xEB / 255, blue: 0xDF / 255)      // #F0EBDF
    static let websiteURL = URL(string: "https://debidong.github.io/pausa/")!

    private static let fontsReady: Bool = {
        for name in ["InstrumentSerif-Regular", "Archivo-Light"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                ?? URL(fileURLWithPath: "App/about/\(name).ttf") as URL?,
               FileManager.default.fileExists(atPath: url.path) {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
        return true
    }()

    /// Builds an un-dilated CoreText vector path for "Pausa" so macOS synthetic font smoothing never thickens its stems.
    private static let pausaGlyphs: (path: Path, size: CGSize) = {
        _ = fontsReady
        let ctFont = CTFontCreateWithName("InstrumentSerif-Regular" as CFString, 50, nil)
        let chars = Array("Pausa".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(ctFont, chars, &glyphs, chars.count)
        var advances = [CGSize](repeating: .zero, count: chars.count)
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &advances, chars.count)
        let cap = CTFontGetCapHeight(ctFont)
        let tracking: CGFloat = -0.75
        let combined = CGMutablePath()
        var x: CGFloat = 0
        for i in 0..<glyphs.count {
            if let gp = CTFontCreatePathForGlyph(ctFont, glyphs[i], nil) {
                let t = CGAffineTransform(translationX: x, y: cap).scaledBy(x: 1, y: -1)
                combined.addPath(gp, transform: t)
            }
            x += advances[i].width + (i < glyphs.count - 1 ? tracking : 0)
        }
        return (Path(combined), CGSize(width: x, height: cap + 2))
    }()

    private static func image(dark: Bool) -> NSImage? {
        let name = dark ? "about-pond-dark" : "about-pond-light"
        return Bundle.main.url(forResource: name, withExtension: "jpg").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(contentsOfFile: "App/about/\(name).jpg")
    }

    @State private var linkHover = false
    @State private var pushedCursor = false

    private func signature(dark: Bool) -> some View {
        let _ = Self.fontsReady
        let wordmark = Self.pausaGlyphs
        let baseInk = dark ? Self.cream : Self.inkLight
        let wordmarkOpacity = linkHover ? (dark ? 0.90 : 0.86) : 0.65
        let underlineOpacity = dark ? 0.42 : 0.36

        return VStack(alignment: .trailing, spacing: 8) {
            Link(destination: Self.websiteURL) {
                wordmark.path
                    .fill(baseInk.opacity(wordmarkOpacity))
                    .frame(width: wordmark.size.width, height: wordmark.size.height)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(baseInk.opacity(underlineOpacity))
                            .frame(height: 0.75)
                            .padding(.horizontal, 1.5)
                            .offset(y: 4)
                            .scaleEffect(x: linkHover ? 1 : 0, y: 1, anchor: .trailing)
                            .opacity(linkHover ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                    .animation(.easeOut(duration: 0.18), value: linkHover)
            }
            .buttonStyle(.plain)
            .blendMode(dark ? .normal : .multiply)
            .onHover { hovering in
                linkHover = hovering
                if hovering && !pushedCursor {
                    NSCursor.pointingHand.push()
                    pushedCursor = true
                } else if !hovering && pushedCursor {
                    NSCursor.pop()
                    pushedCursor = false
                }
            }
            .onDisappear {
                if pushedCursor {
                    NSCursor.pop()
                    pushedCursor = false
                }
            }
            .accessibilityLabel("Pausa")

            Text("by debidong")
                .font(.custom("Archivo-Light", fixedSize: 11.5))
                .tracking(0.48)
                .foregroundStyle(baseInk.opacity(dark ? 0.44 : 0.46))
                .blendMode(dark ? .normal : .multiply)
                .padding(.trailing, 1.5)
        }
        .padding(.trailing, 34)
        .padding(.bottom, 24)
    }

    var body: some View {
        let dark = scheme == .dark
        GeometryReader { g in
            ZStack(alignment: .bottomTrailing) {
                if let img = Self.image(dark: dark) {
                    Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        .frame(width: g.size.width, height: g.size.height).clipped()
                } else {
                    (dark ? Color(white: 0.15) : Color(red: 0.98, green: 0.96, blue: 0.9))
                }
                signature(dark: dark)
            }
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dark ? Color.white.opacity(0.09) : Color.black.opacity(0.06), lineWidth: 0.5)
        )
    }
}

/// System Settings "Appearance"-style chooser: label, then one tile per icon with its name below
/// (round 3b chooser, restored in round 7c). One click switches; the Dock tile follows at once.
struct IconChooser: View {
    @Binding var selection: IconChoice
    @Environment(\.pausaAccent) private var accent
    var body: some View {
        HStack(alignment: .top) {
            Text(L("appearance.icon"))
            Spacer()
            HStack(spacing: 14) {
                ForEach(IconChoice.allCases) { c in
                    let on = c == selection
                    Button { selection = c } label: {
                        VStack(spacing: 5) {
                            Group {
                                if let img = c.image {
                                    // The PNG is an Apple-template icon: 824/1024 tile with transparent margins.
                                    // Scale so the visible tile itself is 64 pt and the ring hugs it.
                                    Image(nsImage: img).resizable().interpolation(.high).antialiased(true)
                                        .frame(width: 64 * 1024 / 824, height: 64 * 1024 / 824)
                                } else {
                                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                                }
                            }
                            .frame(width: 64, height: 64)
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 64 * 185 / 824 + 4)
                                .strokeBorder(on ? accent : .clear, lineWidth: 3))
                            Text(c.title)
                                .font(.callout)
                                .foregroundStyle(on ? .primary : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.title)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }
}

private struct PausaAccentKey: EnvironmentKey { static let defaultValue: Color = Theme.accent }
extension EnvironmentValues {
    /// The theme accent for views that draw their own shapes (selection frames). Set only by pausaTheme.
    var pausaAccent: Color {
        get { self[PausaAccentKey.self] }
        set { self[PausaAccentKey.self] = newValue }
    }
}
extension View {
    /// The ONE place a control colour is set: the selected theme's accent, as tint (switches,
    /// buttons, pickers) and as pausaAccent (custom selection frames).
    func pausaTheme(_ theme: ThemeChoice) -> some View {
        tint(theme.accent).environment(\.pausaAccent, theme.accent)
    }
}

/// Hidden-icon welcome bubble: closes on click.
private final class WelcomePanel: NSPanel {
    override func mouseDown(with event: NSEvent) { close() }
}
