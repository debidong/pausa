import SwiftUI
import Combine

/// What the update UI shows, as plain values: the Settings → 关于 row and the popover line both read it.
/// Fed by `Updater` (live) or set by hand for offscreen renders.
@MainActor
final class UpdateModel: ObservableObject {
    static let shared = UpdateModel()

    @Published var status: UpdateStatus = .idle
    /// The last finished check found nothing. Cleared when a new check starts.
    @Published var upToDate = false
    /// False while a break is on screen: installing would relaunch mid-break.
    @Published var canInstall = true

    var check: () -> Void = {}
    var install: () -> Void = {}

    /// Hook to the live updater. `canInstallNow` is re-read whenever the popover refreshes.
    func bind(_ u: Updater) {
        status = u.status
        u.onStatus = { [weak self] s in
            self?.status = s
            if s == .checking { self?.upToDate = false }
        }
        u.onState = { [weak self] st in
            switch st {
            case .upToDate: self?.upToDate = true
            case .checking: self?.upToDate = false
            default: break
            }
        }
        check = { [weak self] in self?.upToDate = false; u.checkForUpdates() }
        install = { u.installNow() }
    }

    /// Version waiting for a restart, if any. The popover line appears only then.
    var readyVersion: String? {
        if case .ready(let v) = status, !v.isEmpty { return v }
        return nil
    }

    var busy: Bool {
        switch status {
        case .checking, .downloading: return true
        default: return false
        }
    }

    /// The status line under 「检查更新」; nil when there is nothing to say yet.
    var statusText: String? {
        switch status {
        case .checking: return L("正在检查…")
        case .downloading(let v): return v.isEmpty ? L("正在检查…") : L("正在下载 %@", v)
        case .ready(let v): return L("%@ 已就绪，重启后生效", v)
        case .error: return L("暂时无法检查更新")   // feed unreachable etc.; reason is logged (app.pausa/update)
        case .idle: return upToDate ? L("已是最新版本") : nil
        }
    }
}

/// Settings → 关于: one row, like System Settings → 通用 → 软件更新 (status on the left, one button on
/// the right that turns into 「立即重启」 once an update is ready).
struct UpdateRow: View {
    @ObservedObject var model: UpdateModel
    let version: String
    var body: some View {
        // HStack, not LabeledContent: in a grouped Form LabeledContent pins the button to the first
        // text line, so it sat high against the two-line label. Centre it on the whole row.
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("版本 %@", version))
                HStack(spacing: 6) {
                    if model.busy { ProgressView().controlSize(.mini) }
                    Text(line).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Spacer(minLength: 12)
            if model.readyVersion != nil {
                Button(L("立即重启"), action: model.install).disabled(!model.canInstall)
            } else {
                Button(L("检查更新"), action: model.check).disabled(model.busy)
            }
        }
    }
    private var line: String {
        if model.readyVersion != nil, !model.canInstall { return L("%@ 已就绪，重启后生效", model.readyVersion!) + " · " + L("休息结束后安装") }
        return model.statusText ?? L("已开启自动更新")
    }
}

#if DEBUG
/// `Pausa --render-update-ui DIR [--lang xx]`: the 关于 page and the popover in every update state,
/// light and dark, offscreen (no window is ever ordered in).
enum UpdateUISnapshot {
    static let states: [(String, UpdateStatus, Bool, Bool)] = [   // tag, status, upToDate, canInstall
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
                if !can { ps.held = true; ps.status = L("短休息中"); ps.canBreak = false; ps.can5 = false; ps.can15 = false }
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

/// `Pausa --render-theme-picker DIR [--lang xx]`: 通用 page with 主题 = 随机 / 森林, plus the picker's item list,
/// light and dark, offscreen. Dry run: the user's saved theme is never written.
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
        // The open pop-up's items (stand-in for the native menu, which can't be drawn offscreen).
        Settings.shared.theme = .random
        let list = VStack(alignment: .leading, spacing: 0) {
            ForEach(ThemeChoice.scenes + [.random]) { t in
                if t == .random { Divider().padding(.vertical, 4) }
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
            SettingsSnapshot.draw(AnyView(list), width: 180, height: 6 * 22 + 19, ap, "\(dir)/picker-items-\(lang)-\(name).png")
        }
    }
}
#endif
