import AppIntents
import Foundation

/// macOS Focus Filter. The system calls perform() when a Focus that has
/// Pausa's filter turns on, and again with default values when it turns off.
/// Bundled into Contents/Resources/Metadata.appintents by App/build-app.sh via
/// Xcode's `appintentsmetadataprocessor` so System Settings → Focus → Add Filter discovers it.
/// System Settings shows these strings in the system language, not Pausa's: the English text is the
/// key, App/zh-Hans.lproj/Localizable.strings has the Chinese (copied by App/build-app.sh).
@available(macOS 13.0, *)
struct PausaFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Pausa"
    static var description: IntentDescription? = IntentDescription("Pause Pausa's break reminders while this Focus is on. Pausa Settings › Breaks chooses which breaks.")

    @Parameter(title: "Pause Break Reminders", default: true)
    var reduceBreaks: Bool   // stored name kept: filters users already set up keep their value

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: reduceBreaks ? "Break reminders paused" : "Break reminders on")
    }

    func perform() async throws -> some IntentResult {
        PausaDefaults.store.set(reduceBreaks, forKey: DefaultsKey.focusFilterActive)
        await MainActor.run {
            FocusFilterStatus.shared.markSeen()
            NotificationCenter.default.post(name: .pausaFocusFilterChanged, object: nil)
        }
        return .result()
    }
}

extension Notification.Name {
    /// Posted when the Focus Filter turns on/off; read `DefaultsKey.focusFilterActive`.
    static let pausaFocusFilterChanged = Notification.Name("pausaFocusFilterChanged")
}
