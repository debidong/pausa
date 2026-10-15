import AppKit
import SwiftUI
import PausaCore
import Combine

/// Status item: countdown to the next break, text only.
/// Click opens a SwiftUI popover (MenuPopoverView); settings / pause / quit live in its gear menu.
@MainActor
final class MenuBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let app: AppController
    private let popover = NSPopover()
    private let model = PopoverModel()
    private var lastTitle = ""
    private var lastIconKey = ""
    private var settingsWindow: NSWindow?
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
        item.button?.setAccessibilityLabel("Pausa")
        app.onChange = { [weak self] in self?.refresh() }
        langSub = app.settings.$language.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.rebuildContent()
            self?.refresh()
            self?.settingsTabs?.relabel()
            self?.settingsWindow?.title = "Pausa"
        }
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        themeSub = app.settings.$theme.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.rebuildContent()   // popover takes the new accent at once
            DispatchQueue.main.async { self?.lastIconKey = ""; self?.refresh() }   // and the ring
        }
        dockSub = app.settings.$showInDock.receive(on: RunLoop.main).sink { [weak self] on in
            self?.applyDock(on)
        }
        updateSub = UpdateModel.shared.$status.receive(on: RunLoop.main).sink { [weak self] _ in
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

    @objc private func togglePopover() {
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
    func showWelcomeOnce() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "didShowWelcome") else { return }
        d.set(true, forKey: "didShowWelcome")
        let text = L("Pausa 已在运行，下次休息在 %@ 后。", Self.welcomeDuration(app.scheduler.next.remaining))
        let label = Text(text)
            .environment(\.locale, AppLanguage.current.locale)
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .fixedSize()
        if let button = item.button, let w = button.window, w.occlusionState.contains(.visible),
           NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: w.frame.midX, y: w.frame.midY)) }) {
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
            if app.manualPauseUntil == nil { st.statusAppID = app.currentPauseSource?.bundleID }
        }
        st.canBreak = !onBreak
        st.can5 = !held && sch.canPostpone(by: AppController.postponeShort)
        st.can15 = !held && sch.canPostpone(by: AppController.postponeLong)
        st.hardLine = !held && sch.atHardLine && !st.can5
        st.show15 = sch.postponeBudget(n.kind) >= AppController.postponeLong
        st.manualPaused = app.manualPauseUntil != nil
        st.autoPaused = app.isPaused && app.manualPauseUntil == nil
        st.canPause = !sch.longMustNotDefer
        st.update = UpdateModel.shared.readyVersion
        st.canInstall = !onBreak
        UpdateModel.shared.canInstall = !onBreak
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
            var warning = false
            if case .warning = app.scheduler.phase { warning = true }
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

    private func togglePause() { app.manualPauseUntil == nil ? app.pauseForAnHour() : app.resume() }

    /// "关于 Pausa": the About page of the Settings window (no separate panel).
    static weak var shared: MenuBarController?
    static func showAbout() { shared?.showSettings(page: .about) }

#if DEBUG
    /// `--capture-menu out.png [--paused] [--meeting]`: open the real popover, screenshot it, exit.
    func captureMenu(to path: String, paused: Bool, meeting: Bool = false) {
        if paused { app.pauseForAnHour() }
        if meeting { app.simulateReasons([.meeting]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (meeting ? 1.5 : 0.3)) {
            if meeting { self.app.simulateReasons([.meeting]) }
            self.togglePopover()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let sc = Process()
                sc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                sc.arguments = ["-x", path]
                try? sc.run(); sc.waitUntilExit()
                if paused { self.app.resume() }
                print(path); exit(0)
            }
        }
    }

    /// `--verify-lang-switch`: open Settings, switch language vi → zh-Hans in-process, print the sidebar,
    /// toolbar and menu text after each switch, restore the saved language, exit.
    func verifyLanguageSwitch() {
        let original = app.settings.language
        showSettings(page: .breaks)
        func texts(_ v: NSView) -> [String] {
            guard let t = v as? NSTableView else { return [] }
            return (0..<t.numberOfRows).map { r in
                guard let row = t.rowView(atRow: r, makeIfNecessary: true) else { return "?" }
                func walk(_ x: NSView) -> [String] {
                    var o: [String] = []
                    if let f = x as? NSTextField { o.append(f.stringValue) }
                    if let l = x.accessibilityLabel(), !l.isEmpty { o.append(l) }
                    for e in x.accessibilityChildren() ?? [] {
                        if let ev = e as? NSView { o += walk(ev) }
                        else if let el = e as? NSAccessibilityElement, let l = el.accessibilityLabel() { o.append(l) }
                    }
                    return o + x.subviews.flatMap(walk)
                }
                return Array(Set(walk(row))).joined(separator: "/")
            }
        }
        func dump(_ tag: String) {
            guard let frame = settingsWindow?.contentView?.superview else { return }
            func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
            let side = all(frame).first { $0 is NSTableView && $0.frame.width < 250 }
            print("[\(tag)] sidebar rows:", side.map { texts($0).count } ?? 0)
            if let v = side, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                let out = "/tmp/pausa-sidebar-\(tag).png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                print("[\(tag)] sidebar image:", out)
            }
            print("[\(tag)] toolbar title:", settingsWindow?.title ?? "-", "| popover:", MenuPopoverView.kindTitle(.short), L("现在休息"), L("休息延后 %d 分钟", 5))
        }
        var steps: [(TimeInterval, () -> Void)] = [
            (1.0, { self.app.settings.language = .vi }),
            (1.5, { dump("vi") }),
            (0.2, { self.app.settings.language = .zhHans }),
            (1.5, { dump("zh-Hans") }),
            (0.2, { self.app.settings.language = original; exit(0) }),
        ]
        func next() {
            guard !steps.isEmpty else { return }
            let (d, f) = steps.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { f(); next() }
        }
        next()
    }
#endif

    @objc func openSettings() { showSettings(page: nil) }

    func showSettings(page: SettingsPage?) {
        if settingsWindow == nil {
            let (w, tabs) = SettingsTabsController.makeWindow(settings: app.settings,
                                                              onPreview: { [weak app] in app?.previewLong() })
            settingsWindow = w
            settingsTabs = tabs
        }
        if let p = page { settingsTabs?.select(p) }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsTabs?.logFrame("open")
    }
    private var settingsTabs: SettingsTabsController?
}

enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case breaks, general, about
    var id: String { rawValue }
    /// Saved tab id -> page; the removed 外观 tab (round 7) now lives on 通用.
    init?(saved: String) {
        if saved == "appearance" { self = .general } else { self.init(rawValue: saved) }
    }
    var title: String {
        switch self {
        case .breaks: return L("休息"); case .general: return L("通用")
        case .about: return L("关于")
        }
    }
    var symbol: String {
        switch self {
        case .breaks: return "cup.and.saucer"; case .general: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

/// Last-viewed tab (UserDefaults "settingsTab"); the first tab on first open.
final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var page: SettingsPage = SettingsPage(saved: UserDefaults.standard.string(forKey: "settingsTab") ?? "") ?? .breaks {
        didSet { if !Settings.dryRun { UserDefaults.standard.set(page.rawValue, forKey: "settingsTab") } }
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
    static let width: CGFloat = 500

    var body: some View {
        Group {
            switch page {
            case .breaks: BreaksPage(settings: settings)
            case .general: GeneralPage(settings: settings, onPreview: onPreview)
            case .about: AboutPage(settings: settings)
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
    @MainActor static func contentHeight(_ settings: Settings, _ page: SettingsPage) -> CGFloat {
        let v = NSHostingView(rootView: SettingsView(settings: settings, page: page).scrollDisabled(true).fixedSize(horizontal: false, vertical: true))
        return ceil(v.fittingSize.height)
    }
}

/// Native preferences window (like Safari's settings): toolbar tabs with the label under each icon.
/// Round 7c rev 2: first open 500 x 809 pt (whole frame, capped at the visible height), centred. Resizable, minimum 500 x 420, no maximum.
/// All tabs share the window's size; a tab switch never changes it. Position and size are kept under
/// a new autosave key (the old one is never read). Pages scroll inside. Title always "Pausa".
@MainActor
final class SettingsTabsController: NSTabViewController {
    /// Round 7c (j, rev 2): portrait golden ratio 500 × 809, capped at the screen's visible height.
    static let goldenSize = NSSize(width: 500, height: 809)
    static let minimumSize = NSSize(width: 500, height: 420)
    static func initialSize(for screen: NSScreen?) -> NSSize {
        let h = screen?.visibleFrame.height ?? goldenSize.height
        return NSSize(width: goldenSize.width, height: max(minimumSize.height, min(goldenSize.height, h)))
    }
    static let autosave = "PausaSettingsFrame.v3"
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
        w.title = "Pausa"
        w.isReleasedWhenClosed = false
        pinMinimum(w)
        w.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if !w.setFrameUsingName(autosave) {
            w.setFrame(NSRect(origin: w.frame.origin, size: initialSize(for: w.screen ?? NSScreen.main)), display: false)
            w.center()
        }
        tabs.adoptWindowSize()
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
        view.window?.title = "Pausa"
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
        if let f = frameBeforeSwitch, f != w.frame { w.setFrame(f, display: true) }   // size never changes
        frameBeforeSwitch = nil
        w.title = "Pausa"
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

    /// Round 7c diagnostics: the real frame per tab, whenever the user opens Settings or switches tabs.
    /// ~/Library/Logs/Pausa/settings-frames.log
    func logFrame(_ event: String) {
        guard let w = view.window, !Settings.dryRun else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Pausa")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings-frames.log")
        let f = w.frame, c = w.contentView?.frame.size ?? .zero
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(event) tab=\(SettingsNav.shared.page.rawValue) "
            + "frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) content=\(Int(c.width))x\(Int(c.height))\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
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
            settings.shortsBeforeLong = S.clampedCount(settings.shortsBeforeLong, everyMin: v)
        })
    }
    /// An interval is offered only if even the smallest count keeps the long break within 90 minutes.
    static func intervalDisabled(_ m: Int) -> Bool { !Config.allows(everyMin: m, count: S.shortsBeforeLongOptions.first!) }

    var body: some View {
        // Steve: grouped Form, one control per row; the rhythm sentence is the one exception.
        Form {
            Section {
                Picker(L("预设"), selection: Binding(get: { settings.preset }, set: { settings.preset = $0 })) {
                    ForEach(S.Preset.allCases) { Text($0.title).tag($0) }
                }
                RhythmSentence(settings: settings, interval: interval)
            } header: {
                Text(L("休息节奏"))
            }
            Section {
                Picker(L("短休息时长"), selection: $settings.shortLengthSec) {
                    ForEach(S.shortLengthOptions, id: \.self) { v in Text(L("%d 秒", v)).tag(v) }
                }
                Picker(L("长休息时长"), selection: $settings.longLengthMin) {
                    ForEach(S.longLengthOptions, id: \.self) { v in Text(L("%d 分钟", v)).tag(v) }
                }
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
                ForEach(S.shortEveryOptions, id: \.self) { v in Text(L("%d 分钟", v)).tag(v).disabled(BreaksPage.intervalDisabled(v)) }
            })
            line(Plural.pick("rhythm.line2", settings.shortsBeforeLong), Picker("", selection: $settings.shortsBeforeLong) {
                ForEach(S.shortsBeforeLongOptions, id: \.self) { n in
                    Text(verbatim: "\(n)").tag(n).disabled(!Config.allows(everyMin: settings.shortEveryMin, count: n))
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
                Toggle(L("登录时打开"), isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }).animation())
                Picker(selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
                } label: {
                    // Globe after the word so every row's label starts at the same x.
                    HStack(spacing: 5) {
                        Text(L("语言"))
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
                Picker(L("菜单栏显示"), selection: $settings.menuBarDisplay) {
                    ForEach(MenuBarDisplay.allCases) { Text($0.title).tag($0) }
                }
                IconChooser(selection: $settings.icon)
                Toggle(L("在程序坞显示"), isOn: $settings.showInDock.animation())
                Picker(L("配色模式"), selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                Picker(L("主题"), selection: $settings.theme) {
                    ForEach(ThemeChoice.scenes) { Text($0.title).tag($0) }
                    Divider()
                    Text(ThemeChoice.random.title).tag(ThemeChoice.random)
                }
                LabeledContent(L("预览休息界面")) {
                    Button(L("预览"), action: onPreview)
                }
            } header: {
                Text(L("外观"))
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
                Text(L(HealthNote.key))
                    .font(.system(size: 11))
                    // Not .secondary: measured below 4.5:1 on the window background.
                    .foregroundStyle(scheme == .dark ? Color(white: 0.68) : Color(white: 0.36))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            Section {
                UpdateRow(model: .shared, version: version)
            }
        }
        .formStyle(.grouped)
    }
}

/// About top card: watercolor lotus pond (App/about, 1440x600 crops of the day/night art) filling the
/// card, lotus on the left; name and credits on the calm water from 52% width.
/// Light: lotus-leaf greens on cream water (title, body, teal link underlined on hover). Dark: night pond,
/// cream text, cream underlined link.
struct AboutCard: View {
    @Environment(\.colorScheme) private var scheme
    static let height: CGFloat = 220
    static let textStart: CGFloat = 0.52
    static let titleLight = Color(red: 0x24 / 255, green: 0x37 / 255, blue: 0x2D / 255)   // #24372D
    static let bodyLight = Color(red: 0x3A / 255, green: 0x4A / 255, blue: 0x40 / 255)    // #3A4A40
    static let cream = Color(red: 0xF5 / 255, green: 0xEC / 255, blue: 0xD7 / 255)
    private static func image(dark: Bool) -> NSImage? {
        Bundle.main.url(forResource: dark ? "about-pond-dark" : "about-pond-light", withExtension: "jpg")
            .flatMap(NSImage.init(contentsOf:))
    }
    /// Light-mode link: deep teal #2F6B57 instead of system blue, underlined on hover.
    static let linkLight = Color(red: 0x2F / 255, green: 0x6B / 255, blue: 0x57 / 255)
    @State private var linkHover = false

    /// New York title, light body, 8 pt rhythm; text column from 52% of the card.
    private func text(dark: Bool, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pausa").font(.system(size: 28, weight: .semibold, design: .serif))
                .foregroundStyle(dark ? Self.cream : Self.titleLight)
                .padding(.bottom, 4)
            Text(L("名字来自西班牙语中的“暂停”。")).lineSpacing(2)
            Text(L("图标的灵感来自泰国寺庙里的莲花。")).lineSpacing(2)
            Link(destination: URL(string: "https://github.com/debidong")!) {
                Text(L("由 Bowen（debidong）开发"))
                    .foregroundStyle(dark ? Self.cream : Self.linkLight)
                    .underline(dark || linkHover)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onHover { linkHover = $0 }
            .padding(.top, 4)
        }
        .font(.system(size: 13, weight: .light))
        .foregroundStyle(dark ? Self.cream : Self.bodyLight)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading)
        .frame(width: width * (1 - Self.textStart) - 14, alignment: .leading)
        .offset(x: width * Self.textStart)
    }

    var body: some View {
        let dark = scheme == .dark
        GeometryReader { g in
            ZStack(alignment: .leading) {
                if let img = Self.image(dark: dark) {
                    Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        .frame(width: g.size.width, height: g.size.height).clipped()
                } else {
                    (dark ? Color(white: 0.15) : Color(red: 0.98, green: 0.96, blue: 0.9))
                }
                text(dark: dark, width: g.size.width)
            }
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// System Settings "Appearance"-style chooser: label, then one tile per icon with its name below
/// (round 3b chooser, restored in round 7c). One click switches; the Dock tile follows at once.
struct IconChooser: View {
    @Binding var selection: IconChoice
    @Environment(\.pausaAccent) private var accent
    var body: some View {
        HStack(alignment: .top) {
            Text(L("图标"))
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

#if DEBUG
/// `Pausa --render-settings out.png [--all-pages]`: each settings page, light and dark, drawn offscreen.
/// No window is ever shown or made key: the page is laid out in an NSHostingView inside a borderless
/// window that is never ordered in, then drawn with cacheDisplay. The toolbar itself (window chrome)
/// can't be drawn this way; it is only visible on the real Mac.
enum SettingsSnapshot {
    @MainActor static func write(to path: String, pages: Bool) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for p in pages ? SettingsPage.allCases : [SettingsNav.shared.page] {
            for (name, ap) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                let h = SettingsView.contentHeight(.shared, p)
                draw(AnyView(SettingsView(settings: .shared, page: p).scrollDisabled(true)), width: SettingsView.width, height: h, ap,
                     path.replacingOccurrences(of: ".png", with: "-\(p.rawValue)-\(name).png"))
            }
        }
        guard pages else { return }
        // 特定日期 editor (sheet content only; the sheet chrome is real-Mac only).
        let ed = ScheduleEditor.shared
        for (tag, key, kind) in [("date-edit", DateKey(y: 2026, m: 10, d: 11) as DateKey?, DayKind.work), ("date-new", nil, DayKind.off)] {
            ed.editDate(key, key == nil ? nil : kind)
            guard let t = ed.target else { continue }
            for (name, ap) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                draw(AnyView(DateSheet(settings: .shared, editor: ed, t: t)), width: 400, height: 230, ap,
                     path.replacingOccurrences(of: ".png", with: "-\(tag)-\(name).png"))
            }
        }
        ed.target = nil
    }
    @MainActor static func draw(_ v: AnyView, width: CGFloat, height h: CGFloat, _ ap: NSAppearance.Name, _ out: String) {
        do { do {
                let host = NSHostingView(rootView: v
                    .frame(height: h).background(Color(nsColor: .windowBackgroundColor))
                    .toggleStyle(SnapshotSwitchStyle()))   // offscreen: AppKit switches draw inactive (grey)
                host.appearance = NSAppearance(named: ap)
                host.frame = NSRect(x: 0, y: 0, width: width, height: h)
                let w = SnapshotWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
                w.appearance = host.appearance
                w.contentView = host          // never ordered in: nothing appears on screen
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                host.layoutSubtreeIfNeeded(); host.display()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                print(out)
                w.contentView = nil
            }
        }
    }
}

/// Offscreen renders only: an offscreen window's NSSwitch always draws as in an inactive app (grey when on),
/// so snapshots draw the switch in SwiftUI at the same size, filled with the theme accent when on.
struct SnapshotSwitchStyle: ToggleStyle {
    @Environment(\.pausaAccent) private var accent
    func makeBody(configuration c: Configuration) -> some View {
        LabeledContent {
            ZStack(alignment: c.isOn ? .trailing : .leading) {
                Capsule().fill(c.isOn ? accent : Color(nsColor: .quaternaryLabelColor))
                Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5).padding(1.5)
            }
            .frame(width: 26, height: 15)
        } label: { c.label }
    }
}

/// Offscreen snapshot window that claims key/main so controls draw in their active colours.
final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// `Pausa --render-menu out.png [--lang en]`: the menu-bar popover offscreen, light and dark, in a set of
/// sample states (normal, postpone used up, long next, at the 90-minute line, paused).
enum MenuSnapshot {
    static var samples: [(String, PopoverState)] {
        var normal = PopoverState()   // short break: 10-minute allowance, so no 15
        normal.kind = .short; normal.length = 20; normal.remaining = 276; normal.show15 = false
        var used = normal               // allowance used up: 5 greyed
        used.remaining = 876; used.can5 = false; used.can15 = false
        var long = normal               // 30-minute allowance, 20 used: 15 greyed
        long.kind = .long; long.length = 300; long.remaining = 728; long.show15 = true; long.can15 = false
        var longFree = long             // nothing used yet
        longFree.can15 = true
        var limit = long                // 90-minute line: only 现在休息
        limit.hardLine = true; limit.can5 = false; limit.can15 = false; limit.canPause = false
        var paused = normal
        paused.held = true; paused.status = PauseReason.meeting.pausedText; paused.can5 = false; paused.can15 = false
        paused.autoPaused = true
        var manual = normal              // 暂停提醒 1 小时 pressed: the same button reads 恢复提醒
        manual.held = true; manual.status = L("已暂停，%@ 后恢复", "58:00"); manual.can5 = false; manual.can15 = false
        manual.manualPaused = true
        var out = [("1-normal", normal), ("2-used", used), ("3-long", long), ("3b-long-free", longFree), ("4-limit", limit), ("5-paused", paused), ("6-manual-paused", manual)]
        // PauseSource: one paused state per kind with that app's icon (Safari when the app isn't installed),
        // a browser meeting (browser name + icon) and an unknown app (text only, no parentheses).
        func app(_ name: String, _ id: String) -> (String, String) {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil ? (name, id) : ("Safari", "com.apple.Safari")
        }
        let z = app("Zoom", "us.zoom.xos"), t = app("腾讯会议", "com.tencent.meeting"), v = app("IINA", "com.colliderli.iina")
        let k = app("Keynote", "com.apple.iWork.Keynote"), c = app("Google Chrome", "com.google.Chrome")
        let srcs: [(String, PauseSource)] = [
            ("meeting", PauseSource(kind: .meeting, appName: z.0, bundleID: z.1)),
            ("meeting-browser", PauseSource(kind: .meeting, appName: c.0, bundleID: c.1)),
            ("sharing", PauseSource(kind: .screenSharing, appName: t.0, bundleID: t.1)),
            ("video", PauseSource(kind: .video, appName: v.0, bundleID: v.1)),
            ("fullscreen", PauseSource(kind: .fullscreen, appName: k.0, bundleID: k.1)),
            ("unknown", PauseSource(kind: .meeting)),
        ]
        for (tag, src) in srcs {
            var p = paused; p.status = src.statusText; p.statusAppID = src.bundleID
            out.append(("7-source-\(tag)", p))
        }
        return out
    }

    /// Menu-bar item in both 菜单栏图标 modes on a light and a dark bar (offscreen stand-in for the bar).
    @MainActor static func writeBar(to path: String) {
        for (name, dark) in [("light", false), ("dark", true)] {
            do {
                let view = Text(MenuBarController.menuTitle(276)).font(.system(size: 13).monospacedDigit())
                .foregroundColor(dark ? .white : .black)
                .padding(.horizontal, 8).frame(height: 24)
                .padding(.horizontal, 40)
                .background(dark ? Color(white: 0.17) : Color(white: 0.93))
                let r = ImageRenderer(content: view); r.scale = 2
                let out = path.replacingOccurrences(of: ".png", with: "-bar-\(name).png")
                if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)); print(out)
                }
            }
            // 倒计时 ring: running (fraction 0.4), paused (dashed), warning (accent).
            for (tag, f, p, w) in [("ring-running", 0.4, false, false), ("ring-paused", 0.0, true, false), ("ring-warning", 0.95, false, true)] {
                let icon = MenuBarController.icon(fraction: Double(ringStep(fraction: f, paused: p)) / 24, paused: p, warning: w)
                let tint: Color = dark ? .white : .black
                let view = Group {
                    if icon.isTemplate { Image(nsImage: icon).renderingMode(.template).foregroundColor(tint) } else { Image(nsImage: icon) }
                }
                .frame(width: 22, height: 24).padding(.horizontal, 40)
                .background(dark ? Color(white: 0.17) : Color(white: 0.93))
                let r = ImageRenderer(content: view); r.scale = 2
                let out = path.replacingOccurrences(of: ".png", with: "-bar-\(tag)-\(name).png")
                if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)); print(out)
                }
            }
        }
    }

    @MainActor static func write(to path: String) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for (tag, st) in samples {
            for (name, ap) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                let model = PopoverModel(); model.state = st
                let host = NSHostingView(rootView: MenuPopoverView(model: model).pausaTheme(SettingsView.themeOverride ?? Settings.shared.theme)
                    .background(Color(nsColor: .windowBackgroundColor)))
                host.appearance = NSAppearance(named: ap)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                w.appearance = NSAppearance(named: ap)
                w.contentView = host
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                host.layoutSubtreeIfNeeded(); host.display()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let out = path.replacingOccurrences(of: ".png", with: "-\(tag)-\(name).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                print(out)
            }
        }
    }
}


/// `Pausa --render-settings-switch out.png A B`: one live SettingsView rendered under theme A, then the theme is
/// switched in-process to B and the SAME view re-rendered. Restores the user's theme afterwards.
enum ThemeSwitchSnapshot {
    @MainActor static func write(to path: String, from a: ThemeChoice, to b: ThemeChoice) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original = Settings.shared.theme
        defer { Settings.shared.theme = original }
        Settings.shared.theme = a
        let host = NSHostingView(rootView: SettingsView(settings: .shared, page: .general))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        func snap(_ tag: String) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded(); host.display()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            let out = path.replacingOccurrences(of: ".png", with: "-\(tag).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            print(out)
        }
        snap("1-\(a.rawValue)")
        Settings.shared.theme = b
        snap("2-\(b.rawValue)")
    }
}

/// `Pausa --render-interval-menu out.png [--lang en]`: the 休息间隔 menu items (title + enabled state) drawn
/// as a menu, light and dark. Debug only: an open NSMenu can't be captured without screen-recording permission.
enum IntervalMenuSnapshot {
    @MainActor static func write(to path: String) {
        NSApplication.shared.setActivationPolicy(.accessory)
        // SwiftUI builds the pop-up's NSMenu only when it opens, so draw the items from the exact
        // options and predicate the 休息间隔 menu uses.
        let cur = Settings.shared.shortEveryMin
        let items = Settings.shortEveryOptions.map { (title: L("%d 分钟", $0), enabled: !BreaksPage.intervalDisabled($0), on: $0 == cur) }
        for it in items { print(it.enabled ? "  enabled " : "  GREYED  ", it.on ? "✓" : " ", it.title) }
        for (name, ap) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let view = VStack(alignment: .leading, spacing: 0) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        Text(items[i].on ? "✓" : "").frame(width: 12)
                        Text(items[i].title).foregroundColor(items[i].enabled ? .primary : .secondary.opacity(0.6))
                    }
                    .font(.system(size: 13)).padding(.horizontal, 8).frame(height: 22)
                }
            }
            .padding(.vertical, 5).frame(width: 140, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
            .padding(8)
            .environment(\.locale, AppLanguage.current.locale)
            let h = NSHostingView(rootView: view)
            h.appearance = NSAppearance(named: ap)
            h.frame = NSRect(origin: .zero, size: h.fittingSize)
            let win = NSWindow(contentRect: h.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: ap); win.contentView = h
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            h.layoutSubtreeIfNeeded(); h.display()
            guard let rep = h.bitmapImageRepForCachingDisplay(in: h.bounds) else { continue }
            h.cacheDisplay(in: h.bounds, to: rep)
            let out = path.replacingOccurrences(of: ".png", with: "-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            print(out)
        }
    }
}
#endif

/// Hidden-icon welcome bubble: closes on click.
private final class WelcomePanel: NSPanel {
    override func mouseDown(with event: NSEvent) { close() }
}
