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
        case .checking: return L("update.checking")
        case .downloading(let v): return v.isEmpty ? L("update.checking") : L("update.downloading", v)
        case .ready(let v): return L("update.ready", v)
        case .error: return L("update.failed")   // feed unreachable etc.; reason is logged (app.pausa/update)
        case .idle: return upToDate ? L("update.upToDate") : nil
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
                Text(L("about.version", version))
                HStack(spacing: 6) {
                    if model.busy { ProgressView().controlSize(.mini) }
                    Text(line).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Spacer(minLength: 12)
            if model.readyVersion != nil {
                Button(L("update.restart"), action: model.install).disabled(!model.canInstall)
            } else {
                Button(L("update.check"), action: model.check).disabled(model.busy)
            }
        }
    }
    private var line: String {
        if model.readyVersion != nil, !model.canInstall { return L("update.ready", model.readyVersion!) + " · " + L("update.afterBreak") }
        return model.statusText ?? L("update.auto")
    }
}
