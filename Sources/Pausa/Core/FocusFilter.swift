import AppIntents
import Foundation

/// macOS Focus Filter. The system calls perform() when a Focus that has
/// Pausa's filter turns on, and again with default values when it turns off.
/// NOTE: only visible in System Settings → Focus → Add Filter if the bundle carries
/// Metadata.appintents (made by Xcode's appintentsmetadataprocessor; not by SwiftPM/CLT).
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
        UserDefaults.standard.set(reduceBreaks, forKey: "focusFilterActive")
        await MainActor.run {
            FocusFilterStatus.shared.markSeen()
            NotificationCenter.default.post(name: .pausaFocusFilterChanged, object: nil)
        }
        return .result()
    }
}

extension Notification.Name {
    /// Posted when the Focus Filter turns on/off; read UserDefaults "focusFilterActive".
    static let pausaFocusFilterChanged = Notification.Name("pausaFocusFilterChanged")
}
