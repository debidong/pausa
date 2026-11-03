/// 提示音 (spec §5): which breaks chime. Stored by the app under "breakSound"; unknown → longOnly.
public enum BreakSound: String, CaseIterable, Identifiable {
  case off, longOnly, all
  public var id: String { rawValue }
  public func includes(_ kind: BreakKind) -> Bool { self == .all || (self == .longOnly && kind == .long) }
}

/// The two sounds: one when a break starts, one when it runs to its end.
public enum Chime: Equatable { case start, end }

extension Chime {
  /// Someone may be listening: in a call, on the mic, sharing or recording the screen (recording maps
  /// to .screenSharing). Read at the moment of playing.
  public static let silencing: Set<PauseReason> = [.meeting, .micInUse, .screenSharing]

  /// The chime a scheduler command calls for, if any. Only a new break (.startBreak) and a break that
  /// ran to its end (.recorded … .completed) chime. A resumed break, a skip, a snooze, the urgent
  /// exit and the menu pause (all recorded as skipped, or not recorded) stay silent.
  public static func pick(_ c: Command, sound: BreakSound, reasons: Set<PauseReason>) -> Chime? {
    let chime: Chime, kind: BreakKind
    switch c {
    case .startBreak(let k, _): chime = .start; kind = k
    case .recorded(let k, _, .completed): chime = .end; kind = k
    default: return nil
    }
    guard sound.includes(kind), reasons.isDisjoint(with: silencing) else { return nil }
    return chime
  }
}
