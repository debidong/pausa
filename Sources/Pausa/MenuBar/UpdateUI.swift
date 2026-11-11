import SwiftUI
import Combine

/// What the update UI shows, projected directly from `UpdatePhase`: Settings → 关于 and the popover both read it.
@MainActor
final class UpdateModel: ObservableObject {
    static let shared = UpdateModel()

    @Published var phase: UpdatePhase = .idle
    /// False while a break or full-screen preview is on screen: installing would relaunch mid-overlay.
    @Published var canInstall = true

    var check: () -> Void = {}
    var install: () -> Void = {}

    /// Hook to the live updater. `canInstall` is kept current as overlays appear and clear.
    func bind(_ u: Updater) {
        phase = u.phase
        u.onPhaseChange = { [weak self] next in
            self?.phase = next
        }
        check = { u.checkForUpdates() }
        install = { u.installNow() }
    }

    /// Version waiting for a restart, if any. The popover line appears only then.
    var readyVersion: String? {
        if case .readyToInstall(let v) = phase, !v.isEmpty { return v }
        return nil
    }

    var busy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        case .idle, .upToDate, .readyToInstall, .failed: return false
        }
    }

    /// The status line under 「检查更新」; nil when there is nothing to say yet.
    var statusText: String? {
        switch phase {
        case .idle: return nil
        case .checking: return L("update.checking")
        case .upToDate: return L("update.upToDate")
        case .downloading(let v): return v.isEmpty ? L("update.checking") : L("update.downloading", v)
        case .readyToInstall(let v), .installing(let v): return L("update.ready", v)
        case .failed: return L("update.failed")   // feed unreachable etc.; reason is logged (app.pausa/update)
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
        if let v = model.readyVersion, !model.canInstall { return L("update.ready", v) + " · " + L("update.afterBreak") }
        return model.statusText ?? L("update.auto")
    }
}
