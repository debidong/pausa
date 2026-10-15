import Foundation

/// 2-hour cap for every hold reason (Pausa team, 2026-10-15). After `cap` seconds of one
/// reason held continuously, re-check: meeting / screen sharing keep holding while the signal
/// is still there; video / fullscreen are dropped so breaks resume, until that signal ends and
/// starts again fresh. Pure: the caller feeds detector reasons each tick.
public struct PauseCap {
  public static let defaultCap: Double = 2 * 3600
  public static let keepAfterCap: Set<PauseReason> = [.meeting, .screenSharing]
  public var cap: Double
  public private(set) var since: [PauseReason: Double] = [:]
  public private(set) var expired: Set<PauseReason> = []

  public init(cap: Double = PauseCap.defaultCap) { self.cap = cap }

  /// Reasons the scheduler should honour now. `outsideHours` is never capped.
  public mutating func filter(_ reasons: Set<PauseReason>, now: Double) -> Set<PauseReason> {
    for r in since.keys where !reasons.contains(r) { since[r] = nil; expired.remove(r) }   // signal ended: fresh next time
    var out = reasons
    for r in reasons where r != .outsideHours {
      let s = since[r] ?? now
      since[r] = s
      if now - s >= cap {
        if Self.keepAfterCap.contains(r) { since[r] = now }   // re-checked, signal still there: new window
        else { expired.insert(r) }
      }
      if expired.contains(r) { out.remove(r) }
    }
    return out
  }
}
