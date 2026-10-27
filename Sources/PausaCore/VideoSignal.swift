/// Which display-sleep assertions mean "a video is playing". Chrome and other Chromium browsers
/// take the same assertion type (NoDisplaySleepAssertion) for unrelated reasons, told apart only by
/// name: "Video Wake Lock" while a video plays, "Capturing" while a page or extension uses a
/// capture API (fires every ~20 s on fcBowena, 2026-10-20). Only the playback name counts;
/// an unknown name means "can't tell", and then breaks go on as normal (Steve, 2026-10-20).
public enum VideoSignal {
  public static let types: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]
  public static let playbackNames: Set<String> = ["Video Wake Lock"]

  public static func isPlayback(type: String?, name: String?) -> Bool {
    guard let type, let name else { return false }
    return types.contains(type) && playbackNames.contains(name)
  }

  /// One power assertion as read from IOPMCopyAssertionsByProcess.
  public struct Holder { public let pid: Int32, type: String?, name: String?
    public init(pid: Int32, type: String?, name: String?) { self.pid = pid; self.type = type; self.name = name } }

  /// The frontmost app is playing video when it, or a helper of it, holds a playback assertion.
  /// No list of apps: Chrome, Aside, other Chromium builds and Electron apps all qualify by the
  /// assertion alone (Steve, 2026-10-27).
  public static func frontIsPlaying(_ holders: [Holder], belongsToFront: (Int32) -> Bool) -> Bool {
    holders.contains { isPlayback(type: $0.type, name: $0.name) && belongsToFront($0.pid) }
  }
}
