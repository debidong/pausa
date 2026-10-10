import Foundation

/// Why Pausa is currently not interrupting the user.
public enum PauseReason: Hashable, CustomStringConvertible {
    /// A non-virtual microphone or a camera is in use somewhere (plus grace period).
    case meeting
    /// An allowlisted app (video player, game, presentation) covers its display.
    case fullscreen(appName: String)

    /// Menu bar copy, e.g. 「已暂停：正在开会」.
    public var displayText: String {
        switch self {
        case .meeting: return "正在开会"
        case .fullscreen(let name): return "\(name) 全屏中"
        }
    }

    public var description: String {
        switch self {
        case .meeting: return "meeting"
        case .fullscreen(let n): return "fullscreen(\(n))"
        }
    }
}
