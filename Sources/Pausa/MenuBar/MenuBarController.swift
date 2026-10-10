import AppKit
import SwiftUI
import PausaCore

/// Status item: a small circle that fills toward the next break; hollow when paused.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let app: AppController
    private let menu = NSMenu()
    private let statusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var lastIconKey = ""
    private var settingsWindow: NSWindow?

    init(app: AppController) {
        self.app = app
        super.init()
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(.separator())
        menu.addItem(make("立即休息", #selector(breakNow)))
        pauseItem.target = self; pauseItem.action = #selector(togglePause)
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(make("设置…", #selector(openSettings), key: ","))
        menu.addItem(make("退出 Pausa", #selector(quit), key: "q"))
        menu.delegate = self
        item.menu = menu
        item.button?.setAccessibilityLabel("Pausa")
        app.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    private func make(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    /// First launch only: a quiet bubble under the icon so the user knows it is running.
    func showWelcomeOnce() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "didShowWelcome"), let button = item.button else { return }
        d.set(true, forKey: "didShowWelcome")
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        pop.contentViewController = NSHostingController(rootView:
            Text("Pausa 已开始，\(app.settings.shortEveryMin) 分钟后提醒你看看远处")
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .fixedSize())
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { pop.performClose(nil) }
    }

    private func refresh() {
        statusItem.title = app.statusLine
        pauseItem.title = app.manualPauseUntil == nil ? "暂停 1 小时" : "恢复提醒"
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
                NSColor(srgbRed: 0x7F/255.0, green: 0xC8/255.0, blue: 0xA9/255.0, alpha: 1).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            return tinted
        }
        return img
    }

    // MARK: actions

    @objc private func breakNow() { app.breakNow() }
    @objc private func togglePause() { app.manualPauseUntil == nil ? app.pauseForAnHour() : app.resume() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: app.settings)))
            w.title = "Pausa 设置"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    var body: some View {
        Form {
            Stepper("每 \(settings.shortEveryMin) 分钟短休息 20 秒", value: $settings.shortEveryMin, in: 10...60, step: 5)
            Stepper("每 \(settings.longEveryMin) 分钟长休息 3 分钟", value: $settings.longEveryMin, in: 30...120, step: 5)
            Toggle("开机时自动启动", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            Section {
                Text("眼睛持续不适请就医，Pausa 不能替代检查。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize()
    }
}
