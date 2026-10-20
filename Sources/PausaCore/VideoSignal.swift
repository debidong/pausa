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
}
