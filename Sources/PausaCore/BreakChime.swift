/// 提示音 (spec §5): which breaks chime. Stored by the app under "breakSound"; unknown → longOnly.
public enum BreakSound: String, CaseIterable, Identifiable {
  case off, longOnly, all
  public var id: String { rawValue }
  public func includes(_ kind: BreakKind) -> Bool { self == .all || (self == .longOnly && kind == .long) }
}

/// The four sounds: start and end of a short or a long break. The raw value is the bundled file
/// name without ".caf" (App/sounds/, Contents/Resources/sounds/).
public enum Chime: String, CaseIterable, Equatable {
  case longStart = "break-long-start", longEnd = "break-long-end"
  case shortStart = "break-short-start", shortEnd = "break-short-end"
  public var name: String { rawValue }
  public static func start(_ k: BreakKind) -> Chime { k == .long ? .longStart : .shortStart }
  public static func end(_ k: BreakKind) -> Chime { k == .long ? .longEnd : .shortEnd }
}

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
    case .startBreak(let k, _): chime = .start(k); kind = k
    case .recorded(let k, _, .completed): chime = .end(k); kind = k
    default: return nil
    }
    guard sound.includes(kind), reasons.isDisjoint(with: silencing) else { return nil }
    return chime
  }
}
