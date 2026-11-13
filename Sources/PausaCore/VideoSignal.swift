/// Which display-sleep assertions mean "a video is playing". Chrome and other Chromium browsers
/// take the same assertion type (NoDisplaySleepAssertion) for unrelated reasons, told apart only by
/// name: "Video Wake Lock" while a video plays, "Capturing" while a page or extension uses a
/// capture API (fires every ~20 s on fcBowena, 2026-10-20). Only the playback name counts;
/// an unknown name means "can't tell", and then breaks go on as normal (Steve, 2026-10-20).
public enum VideoSignal {
  public static let types: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]
  /// One measured name per line; never guess one (Steve, 2026-10-20). Source: `pmset -g log` on macBowena.
  /// Not here on purpose: "IINA playback is in progress". IINA holds it for audio-only files too
  /// (measured on macBowena 2026-10-27), so it can't tell a movie from music and would keep breaks
  /// suppressed while the user listens to music. When unsure, remind as normal.
  public static let playbackNames: Set<String> = [
    "Video Wake Lock",                              // Chromium: Chrome, Aside (type NoDisplaySleepAssertion)
    "com.apple.WebCore: HTMLMediaElement playback", // Safari (type PreventUserIdleDisplaySleep), 2026-10-23
    // Read from source, not yet measured on macBowena (Steve, 2026-10-27); measure, then drop this note.
    "VLC video playback",                           // VLC video only; "VLC audio playback" is another type and must not count
    "io.mpv.video_playing_back",                    // mpv
  ]

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

  /// Sustained-playback gate + 2-minute post-playback grace (mirrors CallHold).
  /// Embedded Chromium WebViews (e.g. WeChatAppEx on macBowena, 2026-11-06 & 2026-11-13) and
  /// browser feed preloads briefly pulse "Video Wake Lock" for < 1–4 s when no video is being
  /// watched; requiring `minRun` filters transient pulses before latching the 2-minute grace.
  public struct Hold<Owner> {
    public static var minRun: Double { 5 }
    private var active: (owner: Owner, since: Double)?
    private var last: (owner: Owner, at: Double)?

    public init() {}

    public mutating func reset() {
      active = nil
      last = nil
    }

    public mutating func update(
      frontPlaying: Owner?,
      now: Double,
      minRun: Double = Self.minRun,
      grace: Double = CallHold.grace,
      sameOwner: (Owner, Owner) -> Bool
    ) -> Owner? {
      if let current = frontPlaying {
        let since: Double
        if let prev = active, sameOwner(prev.owner, current) {
          since = prev.since
        } else {
          since = now
        }
        active = (current, since)
        if now - since >= minRun {
          last = (current, now)
        }
      } else {
        active = nil
      }
      if let held = last, now - held.at < grace {
        return held.owner
      }
      last = nil
      return nil
    }
  }
}

public extension VideoSignal.Hold where Owner: Equatable {
  mutating func update(
    frontPlaying: Owner?,
    now: Double,
    minRun: Double = Self.minRun,
    grace: Double = CallHold.grace
  ) -> Owner? {
    update(frontPlaying: frontPlaying, now: now, minRun: minRun, grace: grace, sameOwner: ==)
  }
}
