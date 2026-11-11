#if DEBUG
import AppKit
import PausaCore
import SwiftUI

extension MenuBarController {
    /// `--capture-menu out.png [--paused] [--meeting]`: open the real popover, screenshot it, exit.
    func captureMenu(to path: String, paused: Bool, meeting: Bool = false) {
        if paused { app.pause() }
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
        @MainActor func walk(_ x: NSView) -> [String] {
            var o: [String] = []
            if let f = x as? NSTextField { o.append(f.stringValue) }
            if let l = x.accessibilityLabel(), !l.isEmpty { o.append(l) }
            for e in x.accessibilityChildren() ?? [] {
                if let ev = e as? NSView { o += walk(ev) }
                else if let el = e as? NSAccessibilityElement, let l = el.accessibilityLabel() { o.append(l) }
            }
            return o + x.subviews.flatMap { walk($0) }
        }
        @MainActor func texts(_ v: NSView) -> [String] {
            guard let t = v as? NSTableView else { return [] }
            return (0..<t.numberOfRows).map { r in
                guard let row = t.rowView(atRow: r, makeIfNecessary: true) else { return "?" }
                return Array(Set(walk(row))).joined(separator: "/")
            }
        }
        @MainActor func dump(_ tag: String) {
            guard let frame = settingsWindow?.contentView?.superview else { return }
            @MainActor func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap { all($0) } }
            let side = all(frame).first { $0 is NSTableView && $0.frame.width < 250 }
            print("[\(tag)] sidebar rows:", side.map { texts($0).count } ?? 0)
            if let v = side, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                let out = "/tmp/pausa-sidebar-\(tag).png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                print("[\(tag)] sidebar image:", out)
            }
            print("[\(tag)] toolbar title:", settingsWindow?.title ?? "-", "| popover:", MenuPopoverView.kindTitle(.short), L("menu.breakNow"), L("menu.postpone", 5))
        }
        var steps: [(TimeInterval, @MainActor () -> Void)] = [
            (1.0, { self.app.settings.language = .vi }),
            (1.5, { dump("vi") }),
            (0.2, { self.app.settings.language = .zhHans }),
            (1.5, { dump("zh-Hans") }),
            (0.2, { self.app.settings.language = original; exit(0) }),
        ]
        @MainActor func next() {
            guard !steps.isEmpty else { return }
            let (d, f) = steps.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { f(); next() }
        }
        next()
    }
}

/// `Pausa --render-settings out.png [--all-pages]`: each settings page, light and dark, drawn offscreen.
/// No window is ever shown or made key: the page is laid out in an NSHostingView inside a borderless
/// window that is never ordered in, then drawn with cacheDisplay.
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
        let host = NSHostingView(rootView: v
            .frame(height: h).background(Color(nsColor: .windowBackgroundColor))
            .toggleStyle(SnapshotSwitchStyle()))
        host.appearance = NSAppearance(named: ap)
        host.frame = NSRect(x: 0, y: 0, width: width, height: h)
        let w = SnapshotWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        w.appearance = host.appearance
        w.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded(); host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        print(out)
        w.contentView = nil
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

/// `Pausa --render-menu out.png [--lang en]`: the menu-bar popover offscreen, light and dark, in sample states.
enum MenuSnapshot {
    static var samples: [(String, PopoverState)] {
        var normal = PopoverState()
        normal.kind = .short; normal.length = 20; normal.remaining = 276; normal.show15 = false
        var used = normal
        used.remaining = 876; used.can5 = false; used.can15 = false
        var long = normal
        long.kind = .long; long.length = 300; long.remaining = 728; long.show15 = true; long.can15 = false
        var longFree = long
        longFree.can15 = true
        var limit = long
        limit.hardLine = true; limit.can5 = false; limit.can15 = false
        var paused = normal
        paused.held = true; paused.status = PauseReason.meeting.pausedText; paused.can5 = false; paused.can15 = false
        paused.autoPaused = true
        var manual = normal
        manual.held = true; manual.status = L("status.pausedFor", StatsText.duration(2 * 3600 + 10 * 60)); manual.can5 = false; manual.can15 = false
        manual.manualPaused = true
        var out = [("1-normal", normal), ("2-used", used), ("3-long", long), ("3b-long-free", longFree), ("4-limit", limit), ("5-paused", paused), ("6-manual-paused", manual)]
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
            var p = paused; p.status = src.statusText; p.statusAppID = src.bundleID; p.statusAppName = src.displayName
            out.append(("7-source-\(tag)", p))
        }
        return out
    }

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

/// `Pausa --render-settings-switch out.png A B`: one live SettingsView rendered under theme A, then switched to B.
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

/// `Pausa --render-interval-menu out.png [--lang en]`: the 休息间隔 menu items drawn offscreen.
enum IntervalMenuSnapshot {
    @MainActor static func write(to path: String) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let cur = Settings.shared.shortEveryMin
        let items = Settings.shortEveryOptions.map { (title: L("unit.minutes", $0), enabled: !BreaksPage.intervalDisabled($0), on: $0 == cur) }
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

/// `Pausa --render-update-ui DIR [--lang xx]`: the 关于 page and popover in every update state, offscreen.
enum UpdateUISnapshot {
    static let states: [(String, UpdateStatus, Bool, Bool)] = [
        ("1-idle", .idle, false, true), ("2-checking", .checking, false, true), ("3-uptodate", .idle, true, true),
        ("4-downloading", .downloading(version: "0.2.0"), false, true), ("5-ready", .ready(version: "0.2.0"), false, true),
        ("6-ready-onbreak", .ready(version: "0.2.0"), false, false), ("7-error", .error("offline"), false, true),
    ]
    @MainActor static func write(to dir: String) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let m = UpdateModel.shared
        let lang = AppLanguage.current.rawValue
        for (tag, st, ok, can) in states {
            m.status = st; m.upToDate = ok; m.canInstall = can
            for (name, ap) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                let h = SettingsView.contentHeight(.shared, .about)
                SettingsSnapshot.draw(AnyView(SettingsView(settings: .shared, page: .about).scrollDisabled(true)),
                                      width: SettingsView.width, height: h, ap, "\(dir)/about-\(tag)-\(lang)-\(name).png")
                guard tag == "5-ready" || tag == "6-ready-onbreak" || tag == "1-idle" else { continue }
                var ps = MenuSnapshot.samples[0].1
                ps.update = m.readyVersion; ps.canInstall = can
                if !can { ps.held = true; ps.status = L("status.onShortBreak"); ps.canBreak = false; ps.can5 = false; ps.can15 = false }
                let model = PopoverModel(); model.state = ps
                let host = NSHostingView(rootView: MenuPopoverView(model: model).pausaTheme(Settings.shared.theme)
                    .background(Color(nsColor: .windowBackgroundColor)))
                host.appearance = NSAppearance(named: ap)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
                w.appearance = host.appearance
                w.contentView = host
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                host.layoutSubtreeIfNeeded(); host.display()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let out = "\(dir)/menu-\(tag)-\(lang)-\(name).png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                print(out)
                w.contentView = nil
            }
        }
    }
}

/// `Pausa --render-theme-picker DIR [--lang xx]`: 通用 page with 主题 = 随机 / 森林, plus picker items, offscreen.
enum ThemePickerSnapshot {
    @MainActor static func write(to dir: String) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Settings.dryRun = true
        let lang = AppLanguage.current.rawValue
        for t in [ThemeChoice.random, .forest] {
            Settings.shared.theme = t
            for (name, ap) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                let h = SettingsView.contentHeight(.shared, .general)
                SettingsSnapshot.draw(AnyView(SettingsView(settings: .shared, page: .general).scrollDisabled(true)),
                                      width: SettingsView.width, height: h, ap, "\(dir)/general-\(t.rawValue)-\(lang)-\(name).png")
            }
        }
        Settings.shared.theme = .random
        let list = VStack(alignment: .leading, spacing: 0) {
            ForEach(ThemeChoice.scenes + [.random, .softDesktop, .photo]) { t in
                if t == .random || t == .softDesktop { Divider().padding(.vertical, 4) }
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").opacity(t == .random ? 1 : 0).frame(width: 12)
                    Text(t.title)
                    Spacer()
                }
                .padding(.horizontal, 8).frame(height: 22)
            }
        }
        .font(.system(size: 13)).frame(width: 180).padding(.vertical, 5)
        .environment(\.locale, AppLanguage.current.locale)
        for (name, ap) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            SettingsSnapshot.draw(AnyView(list), width: 180, height: 7 * 22 + 2 * 9 + 10, ap, "\(dir)/picker-items-\(lang)-\(name).png")
        }
    }
}
#endif
