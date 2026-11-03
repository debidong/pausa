import AppKit
import PausaCore

/// 提示音 (spec §5): the two bundled sounds (Contents/Resources/sounds/, App/build-app.sh), loaded
/// once. Volume is fixed at 1.0: loudness is in the files, the system volume and mute do the rest.
/// When to play is PausaCore's Chime.pick; a missing file just stays silent.
final class BreakChime {
    private let sounds: [Chime: NSSound]

    init() {
        var s: [Chime: NSSound] = [:]
        for (c, name) in [(Chime.start, "break-start"), (.end, "break-end")] {
            if let url = Self.url(name), let sound = NSSound(contentsOf: url, byReference: true) {
                sound.volume = 1
                s[c] = sound
            }
        }
        sounds = s
    }

    static func url(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "caf", subdirectory: "sounds")
    }

    /// Plays the chime `command` calls for under the current setting and these reasons (read now).
    func play(for command: Command, reasons: Set<PausaCore.PauseReason>) {
        guard let c = Chime.pick(command, sound: Settings.shared.breakSound, reasons: reasons),
              let sound = sounds[c] else { return }
        sound.stop()
        sound.play()
    }
}
