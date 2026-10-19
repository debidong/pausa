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
            SettingItem(title: L("autoPause.meetings"), detail: L("autoPause.meetings.detail"), isOn: $settings.pauseForMeetings)
            SettingItem(title: L("autoPause.video"), detail: L("autoPause.video.detail"), isOn: $settings.pauseForBrowserVideo)
            SettingItem(title: L("autoPause.sharing"), isOn: $settings.pauseForScreenSharing)
            SettingItem(title: L("autoPause.typing"), detail: L("autoPause.typing.detail"), isOn: $settings.pauseWhileTyping)
        } header: {
            // Steve (round 7): renamed 暂停提醒; one caption line under the header, above the rows.
            VStack(alignment: .leading, spacing: 4) {
                Text(L("autoPause.title"))
                Text(L("autoPause.intro"))
                    .font(.footnote).fontWeight(.regular).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Section {
            SettingItem(title: L("autoPause.apps"), isOn: $settings.pauseForCustomApps)
            if settings.pauseForCustomApps {
                ForEach(settings.customPauseApps) { app in AppRows(settings: settings, app: app) }
                LabeledContent(L("autoPause.apps.add")) { Button(L("common.add"), action: addApp) }
            }
        }
        Section {
            SettingItem(title: L("autoPause.focus"), isOn: $settings.pauseForFocusMode)
            if !focus.configured {
                LabeledContent(L("autoPause.focus.missing")) {
                    Button(L("autoPause.focus.openSettings")) { FocusFilterStatus.openSystemSettings() }
                }
            }
        }
        Section {
            Picker(L("autoPause.scope"), selection: $settings.focusModeScope) {
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
            Button(L("common.remove")) { settings.customPauseApps.removeAll { $0.bundleID == app.bundleID } }
        }
        Picker(L("autoPause.condition"), selection: Binding(
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
    var title: String { self == .shortOnly ? L("autoPause.scope.short") : L("autoPause.scope.all") }
}
extension CustomPauseMode {
    var title: String {
        switch self {
        case .foregroundFullscreen: return L("autoPause.condition.frontFullscreen")
        case .foreground: return L("autoPause.condition.front")
        case .running: return L("autoPause.condition.running")
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
        case .browserVideo(let a): return L("pause.videoApp", a)
        case .screenSharing(let a): return a.map { L("pause.sharingApp", $0) } ?? L("pause.sharing")
        case .screenRecording(let a): return a.map { L("pause.recordingApp", $0) } ?? L("pause.recording")
        case .customApp(let a, _): return L("pause.frontmostApp", a)
        case .typing: return L("pause.typing")
        case .focus(let n, let sc):
            let what = sc == .shortOnly ? L("pause.scope.shortPaused") : L("pause.scope.postponed")
            return n.map { L("pause.focusNamed", $0, what) } ?? L("pause.focus", what)
        }
    }
    /// Optional second, secondary line.
    var detail: String? {
        switch self {
        case .browserVideo: return L("pause.videoResume")
        case .screenSharing, .screenRecording: return L("pause.longAfter")
        case .customApp(_, let m): return L("pause.canPostpone", m)
        case .typing(let s): return L("pause.waitUpTo", AppController.clock(s))
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
