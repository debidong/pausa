import Foundation

/// Everything the pre-break panel and the cursor pill show, computed by the Scheduler on every
/// tick. The views only display it: they never count time, work out budgets or decide whether
/// to appear (spec: pre-break notch panel, section 7).
public struct PreBreakState: Equatable {
  public enum Snooze: Equatable {
    case available(minutes: Int)   // 「稍后 N 分钟」 can be tapped
    case usedUp                    // 「不能再延后」, greyed out
    case hidden                    // not shown at all (90-minute line)
  }
  public var kind: BreakKind
  public var secondsLeft: Int      // ceil(remaining); 1…30 while the panel is up; 0 while waiting for typing
  public var snooze: Snooze
  public var canSkip: Bool
  public var atHardLine: Bool
  public var typingWait: Bool
  public var showCard: Bool
  public var showPill: Bool

  public init(kind: BreakKind, secondsLeft: Int, snooze: Snooze, canSkip: Bool, atHardLine: Bool,
              typingWait: Bool, showCard: Bool, showPill: Bool) {
    self.kind = kind; self.secondsLeft = secondsLeft; self.snooze = snooze; self.canSkip = canSkip
    self.atHardLine = atHardLine; self.typingWait = typingWait; self.showCard = showCard; self.showPill = showPill
  }

  /// A panel that would open with fewer seconds left than this stays closed (only the pill
  /// shows), so it never grows and vanishes at once. Once open it stays until 0.
  public static let minOpenSeconds = 5
  /// The cursor pill joins the panel for the last this-many seconds.
  public static let pillSeconds = 10
}
