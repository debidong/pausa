import AppKit
import SwiftUI
import PausaCore
import Combine

/// Status item: a small circle that fills toward the next break; hollow when paused.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let app: AppController
    private let menu = NSMenu()
    private let statusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let countItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let shortRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let longRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let shortView = CountdownRowView(frame: NSRect(x: 0, y: 0, width: 200, height: CountdownRowView.height))
    private let longView = CountdownRowView(frame: NSRect(x: 0, y: 0, width: 200, height: CountdownRowView.height))
    private var widthLanguage: AppLanguage?
    private var lastIconKey = ""
    private var settingsWindow: NSWindow?
    private var titled: [(NSMenuItem, String)] = []   // static items, re-titled on language change
    private var langSub: AnyCancellable?
    private var dockSub: AnyCancellable?

    init(app: AppController) {
        self.app = app
        // macOS 26 auto-adds action icons (a gear on "Settings…"); Pausa's menu stays text-only.
        // App-domain default outranks the global one; read when menu items are first drawn.
        UserDefaults.standard.set(false, forKey: "NSMenuEnableActionImages")
        super.init()
        Self.shared = self
        menu.showsStateColumn = false   // no checkmarks anywhere; lets custom rows align with native text
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        for (row, view, sel) in [(shortRow, shortView, #selector(breakShort)), (longRow, longView, #selector(breakLong))] {
            row.view = view
            row.target = self; row.action = sel          // Return on a highlighted row
            menu.addItem(row)
        }
        shortView.onClick = { [weak self] in self?.breakShort() }
        longView.onClick = { [weak self] in self?.breakLong() }
        countItem.isEnabled = false
        menu.addItem(countItem)
        menu.addItem(.separator())
        pauseItem.target = self; pauseItem.action = #selector(togglePause)
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(make("关于 Pausa", #selector(about)))
        menu.addItem(make("设置…", #selector(openSettings), key: ","))
        menu.addItem(make("退出 Pausa", #selector(quit), key: "q"))
        menu.delegate = self
        item.menu = menu
        item.button?.setAccessibilityLabel("Pausa")
        app.onChange = { [weak self] in self?.refresh() }
        langSub = app.settings.$language.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refresh()
            self?.settingsWindow?.title = "Pausa"
        }
        dockSub = app.settings.$showInDock.receive(on: RunLoop.main).sink { [weak self] on in
            self?.applyDock(on)
        }
        refresh()
    }

    /// Live switch between menu-bar-only (.accessory) and Dock app (.regular); no restart.
    private func applyDock(_ on: Bool) {
        let policy: NSApplication.ActivationPolicy = on ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if on { app.settings.icon.apply() }   // the Dock tile shows the chosen icon
        // A policy change can hide or deactivate our windows; bring Settings back if it was open.
        if let w = settingsWindow, w.isVisible {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                w.center()
                w.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func make(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        titled.append((i, title))
        return i
    }

    // AppController's 1 s timer runs in .common modes, so refresh() keeps ticking while the menu is open.
    func menuWillOpen(_ menu: NSMenu) { refresh() }

    @objc func validateMenuItem(_ i: NSMenuItem) -> Bool {
        (i === shortRow || i === longRow) ? canStartBreak : true
    }

    private var canStartBreak: Bool {
        if case .onBreak = app.scheduler.phase { return false }
        return true
    }

    /// Every string the menu may show in the current language, with widest digits.
    private func fixMenuWidth() {
        let lang = AppLanguage.current
        guard lang != widthLanguage else { return }
        widthLanguage = lang
        var all: [String] = []
        for c in ["59:59", "8:59:59"] {
            all += [L("短休息：%@ 后", c), L("长休息：%@ 后", c), L("已暂停，%@ 后恢复", c)]
        }
        all += [L("立即短休息"), L("立即长休息"), L("你离开了电脑"), L("短休息中"), L("长休息中"),
                L("已暂停：%@", L("正在开会")), L("今天完成 %d/%d 次短休息", 99, 99),
                L("暂停 1 小时"), L("恢复提醒"), L("设置…"), L("退出 Pausa"),
                L("下次开始 %@", L("明天 %@", "23:59")), L("下次开始 %@", "Wed 23:59")]
        let w = CountdownRowView.width(for: all) + 30   // room for native key-equivalent column (⌘Q)
        menu.minimumWidth = w
        for v in [shortView, longView] { v.setFrameSize(NSSize(width: w, height: CountdownRowView.height)) }
    }

    /// First launch only: a quiet bubble under the icon so the user knows it is running.
    func showWelcomeOnce() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "didShowWelcome"), let button = item.button else { return }
        d.set(true, forKey: "didShowWelcome")
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        pop.contentViewController = NSHostingController(rootView:
            Text(L("Pausa 已开始，%d 分钟后提醒你看看远处", app.settings.shortEveryMin))
                .environment(\.locale, AppLanguage.current.locale)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .fixedSize())
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { pop.performClose(nil) }
    }

    private func refresh() {
        for (i, key) in titled { i.title = L(key) }
        fixMenuWidth()
        let r = app.scheduler.remaining
        shortView.idleText = L("短休息：%@ 后", AppController.clock(r.short))
        longView.idleText = L("长休息：%@ 后", AppController.clock(r.long))
        shortView.actionText = L("立即短休息")
        longView.actionText = L("立即长休息")
        let can = canStartBreak
        shortView.enabled = can; longView.enabled = can
        shortRow.isEnabled = can; longRow.isEnabled = can
        // Status line only when something other than counting down is going on.
        statusItem.title = app.statusLine
        statusItem.isHidden = !(app.isPaused || !can)
        countItem.title = app.today.line ?? ""
        countItem.isHidden = app.today.line == nil
        pauseItem.title = app.manualPauseUntil == nil ? L("暂停 1 小时") : L("恢复提醒")
        item.button?.toolTip = app.statusLine

        // Redraw the icon only when it visibly changes (24 steps), not every second.
        let paused = app.isPaused
        var warning = false
        if case .warning = app.scheduler.phase { warning = true }
        let step = Int((app.scheduler.next.fraction * 24).rounded(.down))
        let key = "\(paused)-\(warning)-\(step)"
        guard key != lastIconKey else { return }
        lastIconKey = key
        item.button?.image = Self.icon(fraction: paused ? 0 : Double(step) / 24, paused: paused, warning: warning)
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
        // Template so it follows light/dark menu bar; warning uses the accent tint.
        img.isTemplate = !warning
        if warning {
            let tinted = NSImage(size: size, flipped: false) { rect in
                img.draw(in: rect)
                Theme.accentNS.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            return tinted
        }
        return img
    }

    // MARK: actions

    @objc private func breakShort() { app.breakNow(.short) }
    @objc private func breakLong() { app.breakNow(.long) }
    @objc private func togglePause() { app.manualPauseUntil == nil ? app.pauseForAnHour() : app.resume() }
    @objc private func about() { Self.showAbout() }

    /// "关于 Pausa": the About page of the Settings window (no separate panel).
    static weak var shared: MenuBarController?
    static func showAbout() { shared?.showSettings(page: .about) }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc func openSettings() { showSettings(page: nil) }

    func showSettings(page: SettingsPage?) {
        if let p = page { SettingsNav.shared.page = p }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(settings: app.settings, onPreview: { [weak app] in app?.previewLong() }))
            let w = NSWindow(contentViewController: host)
            w.title = "Pausa"
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            w.setContentSize(SettingsView.size)
            w.isReleasedWhenClosed = false
            settingsWindow = w
            w.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}


enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case breaks, schedule, general, appearance, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .breaks: return L("休息"); case .schedule: return L("Pausa 时段"); case .general: return L("通用")
        case .appearance: return L("外观"); case .about: return L("关于")
        }
    }
    var symbol: String {
        switch self {
        case .breaks: return "cup.and.saucer"; case .schedule: return "calendar.badge.clock"; case .general: return "gearshape"
        case .appearance: return "circle.lefthalf.filled"; case .about: return "info.circle"
        }
    }
}

final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var page: SettingsPage = .breaks
}

/// System Settings-style window: sidebar of pages, each page a grouped Form with standard insets.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var nav = SettingsNav.shared
    var onPreview: () -> Void = {}
    static let size = CGSize(width: 680, height: 520)

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: Binding<SettingsPage?>(get: { nav.page }, set: { if let p = $0 { nav.page = p } })) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            page(nav.page)
                .navigationTitle(nav.page.title)
        }
        .environment(\.locale, AppLanguage.current.locale)
        // Accent derived from the observed settings so a theme switch re-renders live.
        .environment(\.pausaAccent, settings.theme.accent)
        .frame(width: Self.size.width, height: Self.size.height)
    }

    @ViewBuilder func page(_ p: SettingsPage) -> some View {
        switch p {
        case .breaks: BreaksPage(settings: settings)
        case .schedule: SchedulePage(settings: settings)
        case .general: GeneralPage(settings: settings)
        case .appearance: AppearancePage(settings: settings, onPreview: onPreview)
        case .about: AboutPage(settings: settings)
        }
    }
}

/// Pickers stay untinted system pop-ups; only switches and inline numbers take the theme accent.
private struct AccentSwitch: ViewModifier {
    @Environment(\.pausaAccent) var accent
    func body(content: Content) -> some View { content.tint(accent) }
}

struct BreaksPage: View {
    @ObservedObject var settings: Settings
    typealias S = Settings
    var body: some View {
        Form {
            Section {
                Picker(L("节奏"), selection: Binding(get: { settings.preset }, set: { settings.preset = $0 })) {
                    ForEach(S.Preset.allCases) { Text($0.title).tag($0) }
                }
                SentenceRow(template: L("每 {1} 短休息 {2}"), slots: [
                    AnyView(NumberMenu(value: $settings.shortEveryMin, options: S.shortEveryOptions,
                                       recommended: S.recommended.shortEvery, unit: L("分钟"),
                                       disabled: { $0 >= settings.longEveryMin })),
                    AnyView(NumberMenu(value: $settings.shortLengthSec, options: S.shortLengthOptions,
                                       recommended: S.recommended.shortLength, unit: L("秒"))),
                ])
                SentenceRow(template: L("每 {1} 长休息 {2}"), slots: [
                    AnyView(NumberMenu(value: $settings.longEveryMin, options: S.longEveryOptions,
                                       recommended: S.recommended.longEvery, unit: L("分钟"),
                                       disabled: { $0 <= settings.shortEveryMin })),
                    AnyView(NumberMenu(value: $settings.longLengthMin, options: S.longLengthOptions,
                                       recommended: S.recommended.longLength, unit: L("分钟"))),
                ])
            } footer: {
                Text(L(HealthNote.key))
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}

struct GeneralPage: View {
    @ObservedObject var settings: Settings
    var body: some View {
        Form {
            Section {
                Toggle(L("登录时打开"), isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }).animation())
                    .modifier(AccentSwitch())
                Toggle(L("在程序坞中显示"), isOn: $settings.showInDock.animation())
                    .modifier(AccentSwitch())
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
        }
        .formStyle(.grouped)
    }
}

struct AppearancePage: View {
    @ObservedObject var settings: Settings
    var onPreview: () -> Void
    var body: some View {
        Form {
            Section {
                Picker(L("配色模式"), selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent(L("主题")) {
                    HStack {
                        Picker(L("主题"), selection: $settings.theme) {
                            ForEach(ThemeChoice.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Button(L("预览"), action: onPreview)
                    }
                }
                IconChooser(selection: $settings.icon)
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutPage: View {
    @ObservedObject var settings: Settings
    @Environment(\.pausaAccent) private var accent
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0" }
    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Group {
                        if let img = settings.icon.image {
                            Image(nsImage: img).resizable().interpolation(.high).frame(width: 96, height: 96)
                        } else {
                            RoundedRectangle(cornerRadius: 20).fill(.quaternary).frame(width: 80, height: 80).padding(8)
                        }
                    }
                    Text("Pausa").font(.title2.weight(.semibold))
                    Text(L("版本 %@", version)).font(.callout).foregroundStyle(.secondary)
                    VStack(spacing: 4) {
                        Text(L("名字来自西班牙语中的“暂停”。"))
                        Text(L("图标的灵感来自泰国随处可见的莲花。"))
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.top, 6)
                    Link(destination: URL(string: "https://github.com/debidong")!) {
                        Text(L("由 Bowen（debidong）开发"))
                    }
                    .font(.callout)
                    .foregroundStyle(accent)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } footer: {
                Text(L(HealthNote.key))
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}

/// System Settings "Appearance"-style chooser: label, then one tile per icon with its name below.
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

/// A translated sentence with numbered slots ("{1}", "{2}") filled by inline controls.
struct SentenceRow: View {
    let template: String
    let slots: [AnyView]
    var body: some View {
        HStack(spacing: 4) {   // explicit word gap; Menu labels eat surrounding spaces
            ForEach(Array(Sentence.pieces(template).enumerated()), id: \.offset) { _, p in
                switch p {
                case .text(let t): Text(t.trimmingCharacters(in: .whitespaces))
                case .slot(let n): if n >= 1 && n <= slots.count { slots[n - 1] }
                }
            }
        }
    }
}

/// A number inside a sentence that opens a native menu of allowed steps.
/// Dotted underline hints it is clickable; no stepper, no free typing.
struct NumberMenu: View {
    @Binding var value: Int
    let options: [Int]
    let recommended: Int
    let unit: String
    var disabled: (Int) -> Bool = { _ in false }
    @Environment(\.pausaAccent) private var accent

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { v in
                Button {
                    value = v
                } label: {
                    if v == value { Image(systemName: "checkmark") }
                    Text(v == recommended ? L("%d %@（推荐）", v, unit) : "\(v) \(unit)")
                }
                .disabled(disabled(v))
            }
        } label: {
            Text("\(value) \(unit)")
                .monospacedDigit()
                .foregroundStyle(accent)
                .fontWeight(.medium)
                .underline(pattern: .dot, color: accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("\(value) \(unit)")
    }
}

/// `Pausa --render-settings out.png [--all-pages]`: the real Settings window (each page), light and dark.
enum SettingsSnapshot {
    @MainActor static func write(to path: String, pages: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        for p in pages ? SettingsPage.allCases : [SettingsNav.shared.page] {
            SettingsNav.shared.page = p
            for (name, ap) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                let host = NSHostingController(rootView: SettingsView(settings: .shared))
                let w = NSWindow(contentViewController: host)
                w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
                w.toolbarStyle = .unified
                w.title = "Pausa"
                w.appearance = NSAppearance(named: ap)
                w.setContentSize(SettingsView.size)
                w.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                w.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(1.0))
                // No screen-recording permission on the build Mac: draw the layer tree ourselves. Sidebar
                // materials (NSVisualEffectView) can't be rendered offscreen; paint their fallback colour.
                let out = path.replacingOccurrences(of: ".png", with: "-\(p.rawValue)-\(name).png")
                guard let frameView = w.contentView?.superview else { continue }
                func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
                w.appearance?.performAsCurrentDrawingAppearance {
                    for case let e as NSVisualEffectView in all(frameView) {
                        e.wantsLayer = true
                        e.layer?.backgroundColor = (e.material == .sidebar ? NSColor.underPageBackgroundColor : NSColor.windowBackgroundColor).cgColor
                    }
                }
                frameView.layoutSubtreeIfNeeded(); frameView.displayIfNeeded()
                if ProcessInfo.processInfo.environment["PAUSA_DUMP"] != nil {
                    for v in all(frameView) where v is NSTableView {
                        let t = v as! NSTableView
                        print(type(of: t), t.frame, "rows", t.numberOfRows, "hidden", t.isHiddenOrHasHiddenAncestor, "win", t.convert(t.bounds, to: nil))
                    }
                }
                let scale: CGFloat = 2
                let size = frameView.bounds.size
                guard let layer = frameView.layer,
                      let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { continue }
                ctx.scaleBy(x: scale, y: scale)
                if !layer.isGeometryFlipped { }   // CALayer.render draws in layer coords (origin bottom-left on macOS)
                layer.render(in: ctx)
                if let img = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out)); print(out)
                }
                w.orderOut(nil)
            }
        }
    }
}

/// `Pausa --render-menu out.png [--lang en]`: the two countdown rows, normal and highlighted, offscreen.
enum MenuSnapshot {
    @MainActor static func write(to path: String) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let strings = [L("短休息：%@ 后", "7:53"), L("长休息：%@ 后", "37:53"), L("立即短休息"), L("立即长休息")]
        let w = CountdownRowView.width(for: strings + [L("短休息：%@ 后", "59:59")]) + 30
        for (name, ap) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let h = CountdownRowView.height
            let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h * 2 + 10))
            root.wantsLayer = true
            root.layer?.backgroundColor = (ap == .aqua ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.17, alpha: 1)).cgColor
            let a = CountdownRowView(frame: NSRect(x: 0, y: h + 5, width: w, height: h))
            a.idleText = strings[0]; a.actionText = strings[2]; a.forceHighlight = false
            let b = CountdownRowView(frame: NSRect(x: 0, y: 5, width: w, height: h))
            b.idleText = strings[1]; b.actionText = strings[3]; b.forceHighlight = true
            root.addSubview(a); root.addSubview(b)
            let win = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: ap)
            win.contentView = root
            root.layoutSubtreeIfNeeded(); root.display()
            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { continue }
            root.cacheDisplay(in: root.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let out = path.replacingOccurrences(of: ".png", with: "-\(name).png")
            try? png.write(to: URL(fileURLWithPath: out))
            print(out, Int(w))
        }
    }
}

private struct PausaAccentKey: EnvironmentKey { static let defaultValue: Color = .accentColor }
extension EnvironmentValues {
    /// Live theme accent for Settings subviews; set at the SettingsView root from the observed theme.
    var pausaAccent: Color {
        get { self[PausaAccentKey.self] }
        set { self[PausaAccentKey.self] = newValue }
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
        let host = NSHostingView(rootView: SettingsView(settings: .shared))
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
