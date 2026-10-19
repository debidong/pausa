import Foundation

/// Why Pausa is currently not interrupting the user.
public enum PauseReason: Hashable, CustomStringConvertible {
    /// A non-virtual microphone or a camera is in use somewhere (plus grace period).
    case meeting
    /// The mic alone held a minute or more (no camera, no listed meeting app). Same copy as a meeting;
    /// goes through the 2-hour recheck (PausaCore.CallHold).
    case micInUse
    /// An allowlisted app (video player, game, presentation) covers its display.
    case fullscreen(appName: String)
    /// §1: the frontmost browser holds a display-sleep assertion (video playing).
    case browserVideo(appName: String)
    /// §2: screen is being shared (meeting app or browser share bar). Heuristic.
    case screenSharing(appName: String)
    /// §2: a recorder (OBS, CleanShot, QuickTime…) is recording. Heuristic.
    case recording(appName: String)

    /// Full status line. One key per reason so each language can phrase and capitalise it
    /// (English: "Paused: in a meeting").
    public var pausedText: String {
        switch self {
        case .meeting, .micInUse: return L("pause.meeting")
        case .fullscreen(let name): return L("pause.fullscreenApp", name)
        case .browserVideo(let name): return L("pause.videoApp", name)
        case .screenSharing(let name): return L("pause.sharingApp", name)
        case .recording(let name): return L("pause.recordingApp", name)
        }
    }

    /// Scheduler-level reason this maps to.
    var core: PausaCoreReason {
        switch self {
        case .meeting: return .meeting
        case .micInUse: return .micInUse
        case .fullscreen: return .fullscreen
        case .browserVideo: return .video
        case .screenSharing, .recording: return .screenSharing
        }
    }

    public var description: String {
        switch self {
        case .meeting: return "meeting"
        case .micInUse: return "micInUse"
        case .fullscreen(let n): return "fullscreen(\(n))"
        case .browserVideo(let n): return "browserVideo(\(n))"
        case .screenSharing(let n): return "screenSharing(\(n))"
        case .recording(let n): return "recording(\(n))"
        }
    }
}
