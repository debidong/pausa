import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 暂停提醒 groups of the 休息 page. Native controls only.
struct AutoPauseSection: View {
    @ObservedObject var settings: Settings
    @ObservedObject var focus = FocusFilterStatus.shared

    var body: some View {
        // Steve (round 6): four separate Sections; only the first has a header; no footer.
        Section {
            SettingItem(title: L("会议进行时"), detail: L("麦克风或摄像头正在使用"), isOn: $settings.pauseForMeetings)
            SettingItem(title: L("播放视频时"), detail: L("视频播放器和网页里的视频"), isOn: $settings.pauseForBrowserVideo)
            SettingItem(title: L("共享或录制屏幕时"), isOn: $settings.pauseForScreenSharing)
            SettingItem(title: L("输入或拖移时延迟"), detail: L("最长 2 分钟"), isOn: $settings.pauseWhileTyping)
        } header: {
            // Steve (round 7): renamed 暂停提醒; one caption line under the header, above the rows.
            VStack(alignment: .leading, spacing: 4) {
                Text(L("暂停提醒"))
                Text(L("在以下情况下，暂时不提醒休息。"))
                    .font(.footnote).fontWeight(.regular).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Section {
            SettingItem(title: L("使用指定应用时"), isOn: $settings.pauseForCustomApps)
            if settings.pauseForCustomApps {
                ForEach(settings.customPauseApps) { app in AppRows(settings: settings, app: app) }
                LabeledContent(L("添加应用")) { Button(L("添加"), action: addApp) }
            }
        }
        Section {
            SettingItem(title: L("专注模式开启时"), isOn: $settings.pauseForFocusMode)
            if !focus.configured {
                LabeledContent(L("尚未在系统设置中添加 Pausa 专注过滤器")) {
                    Button(L("打开系统设置…")) { FocusFilterStatus.openSystemSettings() }
                }
            }
        }
        Section {
            Picker(L("暂停范围"), selection: $settings.focusModeScope) {
                ForEach(FocusModeScope.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!settings.pauseForFocusMode)
        }
    }

    private func addApp() {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.applicationBundle]
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        guard p.runModal() == .OK else { return }
        for url in p.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                  !settings.customPauseApps.contains(where: { $0.bundleID == id }) else { continue }
            settings.customPauseApps.append(CustomPauseApp(bundleID: id))
        }
    }
}

/// One listed app as two rows (one control each): name + 移除, then 生效条件 + its picker.
private struct AppRows: View {
    @ObservedObject var settings: Settings
    let app: CustomPauseApp
    private var name: String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? app.bundleID
    }
    var body: some View {
        LabeledContent(name) {
            Button(L("移除")) { settings.customPauseApps.removeAll { $0.bundleID == app.bundleID } }
        }
        Picker(L("生效条件"), selection: Binding(
            get: { app.mode },
            set: { m in
                if let i = settings.customPauseApps.firstIndex(where: { $0.bundleID == app.bundleID }) {
                    settings.customPauseApps[i].mode = m
                }
            })) {
            ForEach(CustomPauseMode.allCases) { Text($0.title).tag($0) }
        }
    }
}

extension FocusModeScope {
    var title: String { self == .shortOnly ? L("仅短休息") : L("所有休息") }
}
extension CustomPauseMode {
    var title: String {
        switch self {
        case .foregroundFullscreen: return L("位于前台且全屏")
        case .foreground: return L("位于前台")
        case .running: return L("运行时")
        }
    }
}

/// Whether the user has added Pausa's Focus Filter in System Settings. macOS gives no API to ask;
/// the filter's perform() marks it the first time the system calls it.
final class FocusFilterStatus: ObservableObject {
    static let shared = FocusFilterStatus()
    @Published var configured = UserDefaults.standard.bool(forKey: "focusFilterSeen")
    func markSeen() {
        guard !configured else { return }
        UserDefaults.standard.set(true, forKey: "focusFilterSeen"); configured = true
    }
    static func openSystemSettings() {
        for s in ["x-apple.systempreferences:com.apple.Focus-Settings.extension", "x-apple.systempreferences:com.apple.preference.notifications"] {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }
}

/// Menu-bar status text for the v2 pause reasons (§6.2). Linus's detectors pick the case; this
/// owns the wording so every language stays in one place.
@MainActor enum AutoPauseStatus {
    case browserVideo(app: String)
    case screenSharing(app: String?)
    case screenRecording(app: String?)
    case customApp(app: String, minutesLeft: Int)
    case typing(secondsLeft: Double)
    case focus(name: String?, scope: FocusModeScope)

    /// First line (status row).
    var title: String {
        switch self {
        case .browserVideo(let a): return L("已暂停：%@ 正在播放视频", a)
        case .screenSharing(let a): return a.map { L("已暂停：正在共享屏幕（%@）", $0) } ?? L("已暂停：正在共享屏幕")
        case .screenRecording(let a): return a.map { L("已暂停：正在录屏（%@）", $0) } ?? L("已暂停：正在录屏")
        case .customApp(let a, _): return L("已推迟：%@ 在前台", a)
        case .typing: return L("等你打完这句…")
        case .focus(let n, let sc):
            let what = sc == .shortOnly ? L("短休息已暂停") : L("休息已推迟")
            return n.map { L("专注模式「%@」：%@", $0, what) } ?? L("专注模式：%@", what)
        }
    }
    /// Optional second, secondary line.
    var detail: String? {
        switch self {
        case .browserVideo: return L("视频结束 2 分钟后继续")
        case .screenSharing, .screenRecording: return L("结束后补一次长休息")
        case .customApp(_, let m): return L("还可推迟 %lld 分钟", m)
        case .typing(let s): return L("最多再等 %@", AppController.clock(s))
        case .focus: return nil
        }
    }
}

/// One 自动暂停 setting: a plain Form row, name (+ optional detail line) on the left, one switch on the right.
struct SettingItem: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn.animation()) {
            Text(title)
            if let detail { Text(detail) }
        }
    }
}
