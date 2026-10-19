import Foundation

/// Mic / camera -> hold reason, one tick at a time (pure; PauseDetector feeds it raw signals).
/// - Camera on, or a listed meeting app on the mic (ScreenShareMonitor.meetingBundleIDs): `.meeting`
///   at once. A real call: exempt from the 2-hour recheck (PauseCap.keepAfterCap).
/// - Any other mic use: `.micInUse` once unbroken for `micMinRun`; shorter is dictation (`micPending`:
///   a due break waits, Deferral.microphone). Goes through the 2-hour recheck like other auto-pauses,
///   so a background process holding the mic can't stop breaks for good.
/// Both keep `grace` after their signal stops. Same status copy (「暂停中：正在使用麦克风」).
public struct CallHold {
  public static let micMinRun: Double = Deferral.microphone.cap
  public static let grace: Double = 120
  private var micSince, lastMeeting, lastMic: Double?
  public init() {}

  public struct State: Equatable {
    public var reason: PauseReason?   // .meeting, .micInUse or nil
    public var micPending: Bool       // mic on, not (yet) a hold
  }

  /// `micOn`: a non-input-method process records. `meetingAppMic`: a listed meeting app among them.
  public mutating func update(micOn: Bool, meetingAppMic: Bool, camera: Bool, now: Double) -> State {
    micSince = micOn ? (micSince ?? now) : nil
    let longMic = micSince.map { now - $0 >= Self.micMinRun } ?? false
    if camera || meetingAppMic { lastMeeting = now }
    if longMic { lastMic = now }
    func recent(_ t: Double?) -> Bool { t.map { now - $0 < Self.grace } ?? false }
    let reason: PauseReason? = recent(lastMeeting) ? .meeting : recent(lastMic) ? .micInUse : nil
    return State(reason: reason, micPending: micOn && !longMic && reason == nil)
  }
}
