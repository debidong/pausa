import AppKit
import SwiftUI
import PausaCore

/// Everything the popover shows, as plain values. Built from AppController each tick (or by hand
/// for offscreen renders), so the view has no logic of its own.
struct PopoverState: Equatable {
    var kind: BreakKind = .short
    var length: Double = 20             // seconds of the next break
    var remaining: Double = 0           // until the next break
    var held = false                    // paused / on break: the status line replaces the top line
    var status: String?                 // 「暂停中：正在开会（Zoom）」 etc. while held
    var statusAppID: String?            // bundle ID whose Dock icon leads the app line (PauseSource)
    var statusAppName: String?          // line 2 under the reason: app (or website) name, no parenthesis
    var hardLine = false                // long break due and can no longer be postponed
    var canBreak = true
    var can5 = true, can15 = true
    var show15 = true                   // this break type's total allowance reaches 15 min (round 3 §7)
    var manualPaused = false
    var autoPaused = false
    var canPause = true                 // round 7b: greyed while the long break must not be deferred
    var update: String?                 // a downloaded update waiting for a restart (「有新版本 x.y.z」)
    var canInstall = true               // false during a break: installing relaunches the app
}

struct PopoverActions {
    var breakNow: () -> Void = {}
    var postpone: (Double) -> Void = { _ in }
    var togglePause: () -> Void = {}
    var settings: () -> Void = {}
    var about: () -> Void = {}
    var installUpdate: () -> Void = {}
    var quit: () -> Void = {}
}

final class PopoverModel: ObservableObject {
    @Published var state = PopoverState()
}

struct MenuPopoverView: View {
    @ObservedObject var model: PopoverModel
    var actions = PopoverActions()
    static let width: CGFloat = 300

    private var s: PopoverState { model.state }

    static func kindTitle(_ k: BreakKind) -> String { k == .long ? L("menu.kind.long") : L("menu.kind.short") }
    static func lengthText(_ sec: Double) -> String {
        sec < 60 ? L("unit.seconds", Int(sec.rounded())) : L("unit.minutes", Int((sec / 60).rounded()))
    }
    /// App icon via public NSWorkspace APIs; nil without a bundle ID or when the app isn't installed.
    static func appIcon(_ bundleID: String?) -> NSImage? {
        guard let id = bundleID, !id.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: 16, height: 16)
        return img
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(appName).font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .frame(height: 22)

            // Round 3 §6: one line says how long, which break, and how long it lasts.
            // Steve: the triggering app's own Dock icon, 16 pt, 6 pt before the text; none when unresolvable.
            // Bowen: line 1 the reason, line 2 the app's icon + name; both centred.
            VStack(spacing: 4) {
                Text(s.held ? (s.status ?? "") : topLine)
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .foregroundColor(s.held ? .secondary : .primary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if s.held, let name = s.statusAppName, !name.isEmpty {
                    HStack(alignment: .center, spacing: 6) {
                        if let icon = Self.appIcon(s.statusAppID) {
                            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
                                .accessibilityHidden(true)
                        }
                        Text(name).font(.system(size: 13)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            if s.hardLine {
                Text(L("break.hardLine"))
                    .font(.system(size: 11)).foregroundColor(Color(nsColor: .systemOrange))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            // One row when it fits; long translations wrap to break-now over the postpones.
            // Round 7b: 暂停提醒 1 小时 / 恢复提醒 is a bordered button like 休息延后, alone and centred
            // on the next row, one button gap (6 pt) below. Hidden during an automatic pause.
            VStack(spacing: Self.buttonGap) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Self.buttonGap) { breakButton; postponeButtons }
                    VStack(spacing: Self.buttonGap) { breakButton; HStack(spacing: Self.buttonGap) { postponeButtons } }
                }
                if s.manualPaused || !s.autoPaused {
                    Button(s.manualPaused ? L("menu.resume") : L("menu.pauseHour"), action: actions.togglePause)
                        .buttonStyle(.bordered).fixedSize()
                        .disabled(!s.manualPaused && !s.canPause)
                }
            }
            .controlSize(.small)
            .padding(.top, 10)

            // Steve: the old ⋯ menu becomes two text buttons; 关于 lives in Settings → 关于.
            Divider().padding(.top, 12)
            if let v = s.update {
                // Only when an update is downloaded: one click restarts into it (never mid-break).
                Button(action: actions.installUpdate) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("update.available", v))
                            if !s.canInstall { Text(L("update.afterBreak")).font(.system(size: 11)).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless).disabled(!s.canInstall)
                .padding(.top, 8)
                Divider().padding(.top, 8)
            }
            HStack {
                Button(L("menu.settings"), action: actions.settings).keyboardShortcut(",")
                Spacer()
                Button(L("menu.quit").replacingOccurrences(of: "Pausa", with: appName), action: actions.quit).keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .padding(.top, 8)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)
        .frame(width: Self.width)
        .environment(\.locale, AppLanguage.current.locale)
    }

    static let buttonGap: CGFloat = 6

    private var breakButton: some View {
        Button(L("menu.breakNow"), action: actions.breakNow)
            .buttonStyle(.borderedProminent)
            .disabled(!s.canBreak).fixedSize()
    }

    private var topLine: String {
        L(s.kind == .long ? "menu.next.long" : "menu.next.short", AppController.clock(s.remaining), Self.lengthText(s.length))
    }

    /// While paused, or at the 90-minute line, only 「现在休息」 is left. 15 is hidden when the allowance can never reach it.
    private var postponeButtons: some View {
        ForEach(s.hardLine || s.held ? [] : (s.show15 ? [5, 15] : [5]), id: \.self) { m in
            Button(BreakOverlayController.Copy.snooze(m)) { actions.postpone(Double(m * 60)) }
                .buttonStyle(.bordered).fixedSize()
                .disabled(m == 5 ? !s.can5 : !s.can15)
        }
    }
}
