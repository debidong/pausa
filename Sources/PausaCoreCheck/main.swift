import Foundation

var failures = 0
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, line: UInt = #line) { if a != b { failures += 1; print("FAIL line \(line): \(a) != \(b)") } }
func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double, line: UInt = #line) { if abs(a-b) > accuracy { failures += 1; print("FAIL line \(line): \(a) != \(b)") } }
func XCTAssertTrue(_ c: Bool, line: UInt = #line) { if !c { failures += 1; print("FAIL line \(line)") } }
@testable import PausaCore

final class SchedulerTests {
  func run(_ s: inout Scheduler, from: Double, to: Double, reasons: Set<PauseReason> = [], idle: Double = 10) -> [Command] {
    var out: [Command] = []
    var t = from
    while t <= to { out += s.tick(now: t, reasons: reasons, inputIdle: idle); t += 1 }
    return out
  }

  func testShortBreakAt20Min() {
    var s = Scheduler()
    let cmds = run(&s, from: 0, to: 1200)
    XCTAssertEqual(cmds.first, .showWarning(.short, secondsLeft: 30))
    XCTAssertEqual(cmds.last, .startBreak(.short, length: 20))
  }

  func testEveryThirdBreakIsLong() {
    var s = Scheduler()
    var t = 0.0
    var starts: [BreakKind] = []
    while t <= 3700 {
      for c in s.tick(now: t, reasons: [], inputIdle: 10) {
        if case .startBreak(let k, _) = c { starts.append(k) }
      }
      if case .onBreak = s.phase { _ = s.finish(.completed, now: t) }
      t += 1
    }
    XCTAssertEqual(starts, [.short, .short, .long])
  }

  func testPausedTimeDoesNotCount() {
    var s = Scheduler()
    _ = run(&s, from: 0, to: 600)
    _ = run(&s, from: 601, to: 2900, reasons: [.fullscreen])
    XCTAssertEqual(s.phase, .paused(.fullscreen))
    XCTAssertEqual(s.next.kind, .short)
    XCTAssertEqual(s.next.remaining, 600, accuracy: 2)   // the short clock is frozen
    // Still sitting: at interval × N since the last long break the next one is long (Steve, 2026-10-20).
    _ = run(&s, from: 2901, to: 3100, reasons: [.fullscreen])
    XCTAssertEqual(s.next.kind, .long)
  }

  func longStartAfter(_ s: inout Scheduler, from: Double) -> (Double?, Bool, BreakKind?) {
    var t = from, warned = false
    while t < from + 3600 {
      for c in s.tick(now: t, reasons: [], inputIdle: 10) {
        if case .showWarning(.long, _) = c { warned = true }
        if case .startBreak(let k, _) = c { return (t - from, warned, k) }
      }
      t += 1
    }
    return (nil, warned, nil)
  }

  func testLongMeetingEarnsLongBreak() {
    var s = Scheduler()
    _ = run(&s, from: 0, to: 300)
    _ = run(&s, from: 301, to: 301 + 40 * 60, reasons: [.meeting])   // 40 min meeting
    let (after, warned, kind) = longStartAfter(&s, from: 302 + 40 * 60)
    XCTAssertEqual(kind, .long); XCTAssertTrue(warned)
    XCTAssertEqual(after ?? -1, 180, accuracy: 2)
  }

  func testShortMeetingNearLongEarnsLongBreak() {
    var s = Scheduler()
    var t = 0.0
    while t <= 2700 { _ = s.tick(now: t, reasons: [], inputIdle: 10); if case .onBreak = s.phase { _ = s.finish(.completed, now: t) }; t += 1 }
    _ = run(&s, from: 2701, to: 2701 + 10 * 60, reasons: [.meeting])  // sitting time crosses 50 min
    let (after, _, kind) = longStartAfter(&s, from: 2702 + 600)
    XCTAssertEqual(kind, .long); XCTAssertEqual(after ?? -1, 180, accuracy: 2)
  }

  func testShortMeetingResumes() {
    var s = Scheduler()
    _ = run(&s, from: 0, to: 600)
    _ = run(&s, from: 601, to: 601 + 10 * 60, reasons: [.meeting])
    _ = s.tick(now: 1202, reasons: [], inputIdle: 10)
    XCTAssertEqual(s.remaining.short, 600, accuracy: 2)          // short frozen
    XCTAssertEqual(s.remaining.long, 600 + 2 * 1200, accuracy: 3)   // short next: meeting doesn't move the cycle
  }

  func testMeetingOutranksFullscreen() {
    var s = Scheduler()
    _ = s.tick(now: 0, reasons: [.fullscreen, .meeting], inputIdle: 10)
    XCTAssertEqual(s.phase, .paused(.meeting))
  }

  func testWaitsForTypingButNotForever() {
    var s = Scheduler()
    _ = run(&s, from: 0, to: 1199)
    XCTAssertTrue(run(&s, from: 1200, to: 1228, idle: 0.1).filter { if case .startBreak = $0 { return true }; return false }.isEmpty)
    XCTAssertEqual(run(&s, from: 1229, to: 1230, idle: 0.1).last, .startBreak(.short, length: 20))
  }

  func testLidClosedHourDoesNotFireStaleBreak() {
    var s = Scheduler()
    _ = run(&s, from: 0, to: 1100)
    s.away(.locked, seconds: 3600, now: 4700)
    XCTAssertTrue(run(&s, from: 4700, to: 4710).isEmpty)
    XCTAssertEqual(s.next.kind, .short)
    XCTAssertEqual(s.next.remaining, 1190, accuracy: 2)
  }

  /// No input for 10 minutes without a lock is not getting up: neither clock moves (Steve, 2026-10-20).
  func testIdleIsNotALongBreak() {
    var s = Scheduler()
    _ = run(&s, from: 0, to: 1000, idle: 600)
    XCTAssertEqual(s.next.kind, .short)
    XCTAssertEqual(s.next.remaining, 200, accuracy: 2)
    XCTAssertEqual(s.sinceLastLongBreak, 1000, accuracy: 2)
    XCTAssertEqual(s.remaining.long, 200 + 2 * 1200, accuracy: 3)
  }

  /// Ticks until the next break starts; returns its kind and start time.
  func nextBreak(_ s: inout Scheduler, from t0: Double) -> (BreakKind, Double)? {
    var t = t0
    while t < t0 + 3 * 3600 {
      for c in s.tick(now: t, reasons: [], inputIdle: 10) { if case .startBreak(let k, _) = c { return (k, t) } }
      t += 1
    }
    return nil
  }

  /// Bowen 2026-10-20: a skipped long break comes back as the very next break (min 80), not min 120.
  func testSkippedLongComesBackNext() {
    var s = Scheduler()
    var t = 0.0
    var kinds: [BreakKind] = []
    for _ in 0..<3 { let (k, at) = nextBreak(&s, from: t)!; kinds.append(k); t = at; _ = s.finish(k == .long ? .skipped : .completed, now: t) }
    XCTAssertEqual(kinds, [.short, .short, .long])
    let (k4, at4) = nextBreak(&s, from: t)!
    XCTAssertEqual(k4, .long)
    XCTAssertEqual(at4, 4 * 1200, accuracy: 70)
    XCTAssertEqual(s.finish(.completed, now: at4 + 300).last, .endBreak)
    let (k5, _) = nextBreak(&s, from: at4 + 300)!
    XCTAssertEqual(k5, .short)                       // completed: a new cycle starts
  }

  /// Skipping again and again never gets past the 90-minute line: there the skip is refused.
  func testRepeatedSkipsStopAtNinety() {
    var s = Scheduler()
    var t = 0.0
    var skipped = 0
    while t < 3 * 3600 {
      guard let (k, at) = nextBreak(&s, from: t) else { break }
      t = at
      if k == .short { _ = s.finish(.completed, now: t); continue }
      if s.finish(.skipped, now: t).isEmpty { break }   // refused
      skipped += 1
    }
    XCTAssertEqual(skipped, 2)                       // min 60 and 80; the one at min 100 can't be skipped
    XCTAssertTrue(s.longMustNotDefer)
    XCTAssertTrue(t < 105 * 60)
  }

  /// Snoozing past the limit counts as a skip: the long break is still owed.
  func testSnoozedOutLongStillOwed() {
    var s = Scheduler()
    var t = 0.0
    for _ in 0..<2 { let (_, at) = nextBreak(&s, from: t)!; t = at; _ = s.finish(.completed, now: t) }
    var (k, at) = nextBreak(&s, from: t)!
    XCTAssertEqual(k, .long)
    for _ in 0...s.config.maxSnoozes { _ = s.finish(.snoozed, now: at); (k, at) = nextBreak(&s, from: at)! }
    XCTAssertEqual(k, .long)
  }

  func testReadingWithoutInputStillGetsShortBreak() {
    var s = Scheduler()
    var started: [BreakKind] = []
    var t = 0.0
    while t <= 1300 {
      for c in s.tick(now: t, reasons: [], inputIdle: max(0, t - 100)) {
        if case .startBreak(let k, _) = c { started.append(k) }
      }
      t += 1
    }
    XCTAssertEqual(started.first ?? .long, .short)
  }

  func testSnoozeLimit() {
    var s = Scheduler()
    _ = s.breakNow(.long, now: 0)
    _ = s.finish(.snoozed, now: 1); XCTAssertEqual(s.next.remaining, 300, accuracy: 1)
    _ = s.breakNow(.long, now: 2); _ = s.finish(.snoozed, now: 3)
    _ = s.breakNow(.long, now: 4); _ = s.finish(.snoozed, now: 5)
    XCTAssertEqual(s.next.kind, .short)   // third snooze treated as done
  }

  func testSkippedBreakCountsTowardCycle() {
    var s = Scheduler()   // 20 min × 3rd
    _ = s.breakNow(.short, now: 0); _ = s.finish(.skipped, now: 1)
    _ = s.breakNow(.short, now: 2); _ = s.finish(.completed, now: 3)
    XCTAssertEqual(s.next.kind, .long)
    XCTAssertTrue(s.cycle == (3, 3))
    _ = s.breakNow(.long, now: 4); _ = s.finish(.snoozed, now: 5)
    XCTAssertEqual(s.next.kind, .long)   // a snoozed break comes back as itself
    XCTAssertEqual(s.next.remaining, 300, accuracy: 1)
  }
  func testMeetingCountsWhenLongIsNext() {
    var c = Config(); c.longEveryNth = 1
    var s = Scheduler(config: c)
    _ = run(&s, from: 0, to: 600)
    _ = run(&s, from: 601, to: 900, reasons: [.meeting])   // 5 min meeting, long next: counts
    XCTAssertEqual(s.next.remaining, 300, accuracy: 3)
  }
  func testLegacyLongEveryMigration() {
    XCTAssertEqual(Config.nth(forLegacyLongEveryMin: 50, everyMin: 20, line: 90), 3)   // old default → 标准
    XCTAssertEqual(Config.nth(forLegacyLongEveryMin: 45, everyMin: 20, line: 90), 2)   // old 护眼优先
    XCTAssertEqual(Config.nth(forLegacyLongEveryMin: 60, everyMin: 40, line: 90), 2)   // old 少打扰
    XCTAssertEqual(Config.nth(forLegacyLongEveryMin: 120, everyMin: 20, line: 90), 4)  // capped at 90 min
    XCTAssertEqual(Config.nth(forLegacyLongEveryMin: 30, everyMin: 25, line: 90), 2)   // never below 2
    XCTAssertEqual(Config.nth(forLegacyLongEveryMin: 120, everyMin: 20, line: 60), 3)  // capped at the 60-minute line
    XCTAssertEqual(Config.nth(forLegacyLongEveryMin: 120, everyMin: 20, line: 120), 6) // 120: room for all of it
  }
  func testNthCountConversion() {
    for (n, c) in [(2, 1), (3, 2), (4, 3), (5, 4), (6, 5)] {
      XCTAssertEqual(Config.count(fromNth: n), c); XCTAssertEqual(Config.nth(fromCount: c), n)
    }
    XCTAssertEqual(Config.count(fromNth: 1), 1)                                 // never below 1
    XCTAssertTrue(Config.allows(everyMin: 45, count: 1, line: 90)); XCTAssertTrue(!Config.allows(everyMin: 45, count: 2, line: 90))
    XCTAssertTrue(Config.allows(everyMin: 30, count: 2, line: 90)); XCTAssertTrue(!Config.allows(everyMin: 30, count: 3, line: 90))
    XCTAssertTrue(Config.allows(everyMin: 15, count: 5, line: 90)); XCTAssertTrue(!Config.allows(everyMin: 60, count: 1, line: 90))
    var c = Config(); c.breakEvery = 20 * 60; c.longEveryNth = Config.nth(fromCount: 1)   // default: 1 short, then long
    var s = Scheduler(); s.config = c
    XCTAssertEqual(s.cycle.of, 2)
  }
  func testRingStep() {
    XCTAssertEqual(ringStep(fraction: 0, paused: false), 0); XCTAssertEqual(ringStep(fraction: 0.4, paused: false), 9)
    XCTAssertEqual(ringStep(fraction: 1, paused: false), 24); XCTAssertEqual(ringStep(fraction: 1.7, paused: false), 24)
    XCTAssertEqual(ringStep(fraction: 0.8, paused: true), 0); XCTAssertEqual(ringStep(fraction: .nan, paused: false), 0)
  }
  func testCycleNinetyCap() {
    XCTAssertTrue(Config.allows(everyMin: 20, nth: 3, line: 90)); XCTAssertTrue(Config.allows(everyMin: 40, nth: 2, line: 90))
    XCTAssertTrue(Config.allows(everyMin: 45, nth: 2, line: 90)); XCTAssertTrue(!Config.allows(everyMin: 20, nth: 5, line: 90))
    XCTAssertTrue(!Config.allows(everyMin: 60, nth: 2, line: 90))
  }
  /// spec-hardline acceptance 2: at the 60-minute line, 20 × 3 fits and 30 × 3 does not; 120 lets 60 × 2 in.
  func testHardLineSetting() {
    XCTAssertTrue(Config.allows(everyMin: 20, nth: 3, line: 60)); XCTAssertTrue(!Config.allows(everyMin: 30, nth: 3, line: 60))
    XCTAssertTrue(Config.allows(everyMin: 60, nth: 2, line: 120)); XCTAssertTrue(!Config.allows(everyMin: 45, nth: 2, line: 60))
    XCTAssertEqual(Config.hardLineMinutes(60), 60); XCTAssertEqual(Config.hardLineMinutes(120), 120)
    XCTAssertEqual(Config.hardLineMinutes(0), 90); XCTAssertEqual(Config.hardLineMinutes(75), 90)   // missing / other → 90
    XCTAssertEqual(Config().hardLine, 90 * 60)
  }
  /// spec-hardline §4: line at 60, a 70-minute meeting: the long break starts the tick it ends, no heads-up.
  func testSixtyLineMeetingEndsIntoLongBreak() {
    var c = Config(); c.hardLine = 60 * 60
    var s = Scheduler(config: c)
    _ = run(&s, from: 0, to: 4200, reasons: [.meeting])   // 70 minutes
    XCTAssertTrue(s.longMustNotDefer)
    let out = s.tick(now: 4201, reasons: [], inputIdle: 10)
    XCTAssertEqual(out, [.startBreak(.long, length: c.longLength)])
    XCTAssertTrue(s.finish(.skipped, now: 4202).isEmpty)   // still can't be skipped
  }

  func testBreakEndsOnItsOwn() {
    var s = Scheduler()
    _ = s.breakNow(.short, now: 0)
    XCTAssertEqual(s.tick(now: 20, reasons: [], inputIdle: 10), [.recorded(.short, planned: 20, .completed), .endBreak])
    XCTAssertEqual(s.phase, .working)
  }
}

final class ScheduleTests {
  func cal(_ tz: String, firstWeekday: Int = 1) -> Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: tz)!; c.firstWeekday = firstWeekday; return c
  }
  func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0, in c: Calendar) -> Date {
    c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
  }
  let tp = "Asia/Taipei"
  var work: PausaSchedule {   // weekdays 9:00 – 12:00, 13:30 – 18:30
    PausaSchedule(enabled: true, rules: [
      PausaWindow(start: ClockTime(9), end: ClockTime(12), weekdays: [2,3,4,5,6]),
      PausaWindow(start: ClockTime(13, 30), end: ClockTime(18, 30), weekdays: [2,3,4,5,6])])
  }

  func testCrossMidnight() {
    let c = cal(tp)
    var s = PausaSchedule(enabled: true, rules: [PausaWindow(start: ClockTime(22), end: ClockTime(2), weekdays: [6])]) // Fri
    XCTAssertTrue(isActive(s, at: at(2026,10,16,23, in: c), cal: c))        // Fri 23:00
    XCTAssertTrue(isActive(s, at: at(2026,10,17,1,59, in: c), cal: c))      // Sat 01:59, Friday's window
    XCTAssertTrue(!isActive(s, at: at(2026,10,17,2, in: c), cal: c))        // end exclusive
    XCTAssertTrue(!isActive(s, at: at(2026,10,17,23, in: c), cal: c))       // Sat evening: no rule
    XCTAssertTrue(!isActive(s, at: at(2026,10,16,1, in: c), cal: c))        // Fri 01:00: Thursday has no window
    s.exclude.dates[DateKey(y: 2026, m: 10, d: 17)] = [.allDay]          // skipping Saturday (a calendar day)...
    XCTAssertTrue(!isActive(s, at: at(2026,10,17,1, in: c), cal: c))        // ...also covers Friday's tail on Saturday
    XCTAssertTrue(isActive(s, at: at(2026,10,16,23, in: c), cal: c))        // Friday evening unaffected
    s.exclude.dates = [DateKey(y: 2026, m: 10, d: 16): [.allDay]]           // skipping Friday
    XCTAssertTrue(!isActive(s, at: at(2026,10,16,23, in: c), cal: c))
    XCTAssertTrue(isActive(s, at: at(2026,10,17,1, in: c), cal: c))         // the tail after midnight is Saturday
  }

  func testTimeZoneSwitch() {
    let t = at(2026,10,12,9,30, in: cal(tp))                                 // Mon 09:30 Taipei = Mon 01:30 UTC
    XCTAssertTrue(isActive(work, at: t, cal: cal(tp)))
    XCTAssertTrue(!isActive(work, at: t, cal: cal("UTC")))
    XCTAssertTrue(isActive(work, at: t, cal: cal("Asia/Tokyo")))         // 10:30 Tokyo
  }

  func testDSTStart() {   // New York 2026-03-08 (Sun): 02:00 -> 03:00
    let c = cal("America/New_York")
    let s = PausaSchedule(enabled: true, rules: [PausaWindow(start: ClockTime(1), end: ClockTime(4), weekdays: [1])])
    let t159 = at(2026,3,8,1,59, in: c)
    XCTAssertTrue(isActive(s, at: t159, cal: c))
    XCTAssertTrue(isActive(s, at: t159.addingTimeInterval(60), cal: c))  // wall 03:00 EDT, still inside
    XCTAssertTrue(!isActive(s, at: at(2026,3,8,4, in: c), cal: c))
    // A window entirely inside the gap never runs, and nothing crashes.
    let gap = PausaSchedule(enabled: true, rules: [PausaWindow(start: ClockTime(2), end: ClockTime(3), weekdays: [1])])
    var x = at(2026,3,8,0, in: c); var any = false
    while x < at(2026,3,8,5, in: c) { any = any || isActive(gap, at: x, cal: c); x += 60 }
    XCTAssertTrue(!any)
    XCTAssertTrue(nextStart(gap, after: at(2026,3,8,0, in: c), cal: c) != nil)
  }

  func testDSTEnd() {     // New York 2026-11-01 (Sun): 02:00 EDT -> 01:00 EST
    let c = cal("America/New_York")
    let s = PausaSchedule(enabled: true, rules: [PausaWindow(start: ClockTime(1), end: ClockTime(2), weekdays: [1])])
    let first = at(2026,11,1,1,30, in: c)
    XCTAssertTrue(isActive(s, at: first, cal: c))
    XCTAssertTrue(isActive(s, at: first.addingTimeInterval(3600), cal: c))  // repeated 01:30 EST: wall clock, still inside
    XCTAssertTrue(!isActive(s, at: first.addingTimeInterval(7200), cal: c)) // 02:30 EST
  }

  func testOverrideOff() {
    let c = cal(tp); var s = work
    s.exclude.dates[DateKey(y: 2026, m: 10, d: 12)] = [.allDay]
    XCTAssertTrue(!isActive(s, at: at(2026,10,12,10, in: c), cal: c))
    XCTAssertTrue(isActive(s, at: at(2026,10,13,10, in: c), cal: c))
  }

  func testOverrideWindows() {
    let c = cal(tp); var s = work
    s.include.dates[DateKey(y: 2026, m: 10, d: 10)] = [ClockRange(ClockTime(9), ClockTime(18))]  // Sat make-up day
    XCTAssertTrue(isActive(s, at: at(2026,10,10,12,30, in: c), cal: c))
    XCTAssertTrue(!isActive(s, at: at(2026,10,10,19, in: c), cal: c))
    XCTAssertTrue(!isActive(s, at: at(2026,10,11,12, in: c), cal: c))       // Sunday untouched
    // Weekly exclude (lunch) wins over include, and over a make-up day.
    s.exclude.rules = [PausaWindow(start: ClockTime(12), end: ClockTime(13, 30), weekdays: [1,2,3,4,5,6,7])]
    XCTAssertTrue(!isActive(s, at: at(2026,10,10,12,30, in: c), cal: c))
    XCTAssertTrue(isActive(s, at: at(2026,10,10,13,30, in: c), cal: c))
    XCTAssertTrue(isActive(s, at: at(2026,10,12,11,59, in: c), cal: c))
    // A skipped date wins over a make-up window on the same date.
    s.exclude.dates[DateKey(y: 2026, m: 10, d: 10)] = [.allDay]
    XCTAssertTrue(!isActive(s, at: at(2026,10,10,10, in: c), cal: c))
  }

  func testDisabledRule() {
    let c = cal(tp); var s = work; s.rules[0].enabled = false
    XCTAssertTrue(!isActive(s, at: at(2026,10,12,10, in: c), cal: c))
    XCTAssertTrue(isActive(s, at: at(2026,10,12,14, in: c), cal: c))
  }

  func testScheduleDisabled() {
    let c = cal(tp); var s = work; s.enabled = false
    XCTAssertTrue(isActive(s, at: at(2026,10,11,3, in: c), cal: c))         // Sun 03:00
    XCTAssertTrue(nextStart(s, after: at(2026,10,11,3, in: c), cal: c) == nil)
    XCTAssertTrue(nextStart(PausaSchedule(enabled: true), after: at(2026,10,11,3, in: c), cal: c) == nil)  // no windows at all
  }

  func testFirstWeekdayIrrelevant() {
    let a = cal(tp, firstWeekday: 1), b = cal(tp, firstWeekday: 2)
    var s = work; s.rules.append(PausaWindow(start: ClockTime(23), end: ClockTime(1), weekdays: [1, 7]))
    var t = at(2026,10,10,0, in: a); var same = true
    while t < at(2026,10,18,0, in: a) {
      same = same && isActive(s, at: t, cal: a) == isActive(s, at: t, cal: b)
                  && nextStart(s, after: t, cal: a) == nextStart(s, after: t, cal: b)
      t += 1800
    }
    XCTAssertTrue(same)
  }

  func testNextStart() {
    let c = cal(tp); var s = work
    XCTAssertEqual(nextStart(s, after: at(2026,10,16,19, in: c), cal: c), at(2026,10,19,9, in: c))      // Fri evening -> Mon
    XCTAssertEqual(nextStart(s, after: at(2026,10,12,10, in: c), cal: c), at(2026,10,12,13,30, in: c))  // inside morning -> afternoon
    s.include.dates[DateKey(y: 2026, m: 10, d: 10)] = [ClockRange(ClockTime(9), ClockTime(18))]
    s.exclude.dates[DateKey(y: 2026, m: 10, d: 12)] = [.allDay]
    XCTAssertEqual(nextStart(s, after: at(2026,10,9,19, in: c), cal: c), at(2026,10,10,9, in: c))       // Fri -> Sat make-up day
    XCTAssertEqual(nextStart(s, after: at(2026,10,10,19, in: c), cal: c), at(2026,10,13,9, in: c))      // skips Sun + Mon off
    // Lunch exclude inside an include window: next start is the end of lunch.
    s.rules = [PausaWindow(start: ClockTime(9), end: ClockTime(18), weekdays: [2,3,4,5,6])]
    s.exclude.rules = [PausaWindow(start: ClockTime(12), end: ClockTime(13, 30), weekdays: [2,3,4,5,6])]
    XCTAssertEqual(nextStart(s, after: at(2026,10,13,12,10, in: c), cal: c), at(2026,10,13,13,30, in: c))
    XCTAssertEqual(nextStart(s, after: at(2026,10,13,10, in: c), cal: c), at(2026,10,13,13,30, in: c))   // active now -> after lunch
  }

  func testDayKinds() {
    let c = cal(tp); var s = work
    s.days[DateKey(y: 2026, m: 10, d: 10)] = .work    // Sat 上班: Monday hours
    s.days[DateKey(y: 2026, m: 10, d: 12)] = .off     // Mon 休息
    XCTAssertTrue(isActive(s, at: at(2026,10,10,10, in: c), cal: c))
    XCTAssertTrue(!isActive(s, at: at(2026,10,10,20, in: c), cal: c))
    XCTAssertTrue(!isActive(s, at: at(2026,10,12,10, in: c), cal: c))
    XCTAssertEqual(nextStart(s, after: at(2026,10,9,19, in: c), cal: c), at(2026,10,10,9, in: c))
    let json = #"{"enabled":true,"include":{"rules":[],"dates":[{"y":2026,"m":10,"d":10},[{"start":{"minutes":540},"end":{"minutes":1080}}]]},"exclude":{"rules":[],"dates":[{"y":2026,"m":10,"d":12},[{"start":{"minutes":0},"end":{"minutes":0}}]]}}"#
    let v2 = try? JSONDecoder().decode(PausaSchedule.self, from: Data(json.utf8))
    XCTAssertEqual(v2?.days, [DateKey(y: 2026, m: 10, d: 10): .work, DateKey(y: 2026, m: 10, d: 12): .off])
    XCTAssertTrue(v2?.include.dates.isEmpty == true)
    let j2 = #"{"enabled":true,"include":{"rules":[],"dates":[]},"exclude":{"rules":[],"dates":[{"y":2026,"m":10,"d":14},[{"start":{"minutes":720},"end":{"minutes":780}}]]}}"#
    XCTAssertEqual((try? JSONDecoder().decode(PausaSchedule.self, from: Data(j2.utf8)))?.days, [DateKey(y: 2026, m: 10, d: 14): .work])
  }
  func testWorkdayUnionsWeekdayRules() {
    let c = cal(tp); let sat = DateKey(y: 2026, m: 10, d: 10)
    var s = PausaSchedule(enabled: true, rules: [
      PausaWindow(start: ClockTime(9), end: ClockTime(12), weekdays: [2]),          // Mon only
      PausaWindow(start: ClockTime(11), end: ClockTime(15), weekdays: [6, 7]),      // Fri+Sat: has a weekday
      PausaWindow(start: ClockTime(19), end: ClockTime(21), weekdays: [1, 7])])     // weekend only: not on 上班
    s.exclude.rules = [PausaWindow(start: ClockTime(13), end: ClockTime(14), weekdays: [4])]  // Wed quiet hours
    s.days[sat] = .work
    XCTAssertTrue(isActive(s, at: at(2026,10,10,9,30, in: c), cal: c))     // Mon range
    XCTAssertTrue(isActive(s, at: at(2026,10,10,12,30, in: c), cal: c))    // union 9–15
    XCTAssertTrue(!isActive(s, at: at(2026,10,10,13,30, in: c), cal: c))   // weekday quiet hours apply
    XCTAssertTrue(isActive(s, at: at(2026,10,10,14,30, in: c), cal: c))
    XCTAssertTrue(!isActive(s, at: at(2026,10,10,20, in: c), cal: c))      // weekend-only rule skipped
    XCTAssertTrue(!isActive(s, at: at(2026,10,10,16, in: c), cal: c))
    s.days[sat] = .off
    XCTAssertTrue(!isActive(s, at: at(2026,10,10,9,30, in: c), cal: c))    // 休息: nothing all day
    XCTAssertTrue(!isActive(s, at: at(2026,10,10,20, in: c), cal: c))
    s.enabled = false; s.days[sat] = .work
    XCTAssertTrue(isActive(s, at: at(2026,10,10,20, in: c), cal: c))       // switch off: reminds normally
  }
  func testMigrationV1() {
    let c = cal(tp)
    let json = #"{"enabled":true,"rules":[{"id":"6F1D2E3C-0000-0000-0000-000000000001","start":{"minutes":540},"end":{"minutes":1080},"weekdays":[2,3,4,5,6],"enabled":true}],"overrides":[{"y":2026,"m":10,"d":12},{"off":{}},{"y":2026,"m":10,"d":10},{"windows":{"_0":[{"start":{"minutes":540},"end":{"minutes":1080}}]}}]}"#
    guard let s = try? JSONDecoder().decode(PausaSchedule.self, from: Data(json.utf8)) else { XCTAssertTrue(false); return }
    XCTAssertTrue(s.enabled)
    XCTAssertEqual(s.rules.count, 1)
    XCTAssertTrue(!isActive(s, at: at(2026,10,12,10, in: c), cal: c))       // off -> skipped date
    XCTAssertTrue(isActive(s, at: at(2026,10,10,10, in: c), cal: c))        // windows -> make-up date
    let round = try? JSONDecoder().decode(PausaSchedule.self, from: JSONEncoder().encode(s))
    XCTAssertEqual(round, s)
  }
  // Scheduler + 时段 edges: Mon 2026-10-12, window 09:00 – 12:00, driven minute by minute.
  func testSchedulerPausesOutsideHoursAndStartsFresh() {
    let c = cal(tp); let s = work
    var sch = Scheduler(); var gate = HoursGate()
    let t0 = at(2026,10,12,8,50, in: c)
    var mono = 0.0; var starts: [Double] = []; var freshAt: Date?
    var w = t0
    while w < at(2026,10,12,9,30, in: c) {
      let active = isActive(s, at: w, cal: c)
      if gate.update(active) { sch.startFresh(now: mono); freshAt = w }
      for cmd in sch.tick(now: mono, reasons: active ? [] : [.outsideHours], inputIdle: 10) {
        if case .startBreak = cmd { starts.append(mono) }
      }
      if case .onBreak = sch.phase { _ = sch.finish(.completed, now: mono) }
      if w < at(2026,10,12,9, in: c) { XCTAssertEqual(sch.phase, .paused(.outsideHours)) }
      w += 1; mono += 1
    }
    XCTAssertEqual(freshAt, at(2026,10,12,9, in: c))
    XCTAssertEqual(starts.count, 1)
    XCTAssertEqual(starts.first ?? -1, 600 + 1200, accuracy: 2)   // 20 min after 09:00, not after 08:50
  }

  func testWindowEndPausesMidCount() {
    let c = cal(tp); let s = work
    var sch = Scheduler(); var gate = HoursGate()
    var w = at(2026,10,12,11,50, in: c); var mono = 0.0
    while w < at(2026,10,12,12,30, in: c) {
      let active = isActive(s, at: w, cal: c)
      if gate.update(active) { sch.startFresh(now: mono) }
      _ = sch.tick(now: mono, reasons: active ? [] : [.outsideHours], inputIdle: 10)
      w += 1; mono += 1
    }
    XCTAssertEqual(sch.phase, .paused(.outsideHours))
    XCTAssertEqual(sch.remaining.short, 1200 - 600, accuracy: 2)   // only 11:50 – 12:00 counted
  }

  func testMeetingOutranksOutsideHours() {
    var sch = Scheduler()
    _ = sch.tick(now: 0, reasons: [.outsideHours, .meeting], inputIdle: 10)
    XCTAssertEqual(sch.phase, .paused(.meeting))
  }

  func testManualBreakOutsideHours() {
    var sch = Scheduler()
    _ = sch.tick(now: 0, reasons: [.outsideHours], inputIdle: 10)
    XCTAssertEqual(sch.breakNow(.short, now: 1), [.startBreak(.short, length: 20)])
  }

  func testNextChange() {
    let c = cal(tp); var s = work
    XCTAssertEqual(nextChange(s, after: at(2026,10,12,10, in: c), cal: c), at(2026,10,12,12, in: c))
    XCTAssertEqual(nextChange(s, after: at(2026,10,16,19, in: c), cal: c), at(2026,10,19,9, in: c))
    s.rules.append(PausaWindow(start: ClockTime(22), end: ClockTime(2), weekdays: [2]))
    XCTAssertEqual(nextChange(s, after: at(2026,10,12,23, in: c), cal: c), at(2026,10,13,2, in: c))
    s.enabled = false
    XCTAssertTrue(nextChange(s, after: at(2026,10,12,10, in: c), cal: c) == nil)
  }
}


final class DeferralTests {
  // Long-only config: short breaks never get in the way.
  func longOnly(_ min: Double = 50) -> Scheduler { Scheduler(config: cfg(min)) }
  /// Every break is long, `min` apart (N = 1): isolates long-break rules from the cycle.
  func cfg(_ min: Double) -> Config { var c = Config(); c.breakEvery = min * 60; c.longEveryNth = 1; return c }
  /// Ticks until a break starts; returns the start time or nil.
  func startAt(_ s: inout Scheduler, from: Double, to: Double, reasons: Set<PauseReason> = [], d: [Deferral] = []) -> Double? {
    var t = from
    while t <= to {
      for c in s.tick(now: t, reasons: reasons, deferrals: d, inputIdle: 10) { if case .startBreak = c { return t } }
      t += 1
    }
    return nil
  }

  func testTypingCappedAt30s() {
    var s = Scheduler()
    XCTAssertEqual(startAt(&s, from: 0, to: 2000, d: [.typing]) ?? -1, 1200 + 30, accuracy: 2)
  }
  /// R21: the wait for a pause in typing comes out of the shared budget.
  func testTypingGraceUsesBudget() {
    var s = Scheduler()
    var t = 0.0
    while t < 1200 { _ = s.tick(now: t, reasons: [], inputIdle: 10); t += 1 }
    let before = s.deferralLeft
    while t < 1215 { _ = s.tick(now: t, reasons: [], inputIdle: 0.1); t += 1 }
    XCTAssertEqual(before - s.deferralLeft, 15, accuracy: 2)
  }
  /// R21: budget spent, typing no longer delays the break.
  func testTypingGraceStopsWhenBudgetSpent() {
    var s = Scheduler()
    _ = s.tick(now: 0, reasons: [], inputIdle: 10)
    XCTAssertTrue(s.postpone(by: 300)); XCTAssertTrue(s.postpone(by: 300))   // short budget spent
    var t = 1.0, start = -1.0
    while t < 3000 && start < 0 {
      for c in s.tick(now: t, reasons: [], inputIdle: 0.1) { if case .startBreak = c { start = t } }
      t += 1
    }
    XCTAssertEqual(start, 1800, accuracy: 2)
  }
  /// R20: past the 90-minute line the long break starts on time even mid-typing.
  func testTypingNeverDelaysForcedLong() {
    var s = Scheduler(config: cfg(95))
    var t = 0.0, start = -1.0
    while t < 9000 && start < 0 {
      for c in s.tick(now: t, reasons: [], deferrals: [.typing], inputIdle: 0.1) { if case .startBreak = c { start = t } }
      t += 1
    }
    XCTAssertEqual(start, 5700, accuracy: 2)
  }
  func testMenuPostponeShortBudget() {
    var s = Scheduler()   // short budget 10 min: +5, +5, then greyed out
    _ = s.tick(now: 0, reasons: [], inputIdle: 10)
    XCTAssertTrue(s.postpone(by: 300)); XCTAssertTrue(s.postpone(by: 300))
    XCTAssertTrue(!s.canPostpone(by: 300)); XCTAssertTrue(!s.postpone(by: 300))
    XCTAssertEqual(startAt(&s, from: 1, to: 3000) ?? -1, 1200 + 600, accuracy: 2)
  }
  func testMenuPostponeLongStopsAtNinety() {
    let c = cfg(85)
    var s = Scheduler(config: c)   // only 5 min left before the 90-minute line
    _ = s.tick(now: 0, reasons: [], inputIdle: 10)
    XCTAssertTrue(!s.canPostpone(by: 900)); XCTAssertTrue(s.postpone(by: 300))
    XCTAssertEqual(s.postponeLeft, 0, accuracy: 1)
  }
  func testShortBudgetCapsFocusApp() {
    var s = Scheduler()   // focus app may defer 15 min, but a short break only 10
    XCTAssertEqual(startAt(&s, from: 0, to: 3000, d: [.focusApp()]) ?? -1, 1200 + 600, accuracy: 2)
  }
  func testFocusModeShortOnlyDoesNotDeferLong() {
    var s = longOnly()
    XCTAssertEqual(startAt(&s, from: 0, to: 5000, d: [.focusMode(shortOnly: true)]) ?? -1, 3000, accuracy: 2)
  }
  func testSharedBudgetConcurrentCountsOnce() {
    var s = longOnly()   // two sources at once still only 15 min (each cap), not 30
    XCTAssertEqual(startAt(&s, from: 0, to: 9000, d: [.focusApp(), .focusMode(shortOnly: false)]) ?? -1, 3000 + 900, accuracy: 2)
  }
  func testSharedBudgetSequentialStopsAt30() {
    var s = longOnly()
    XCTAssertTrue(startAt(&s, from: 0, to: 3000 + 899, d: [.focusApp()]) == nil)
    XCTAssertTrue(startAt(&s, from: 3900, to: 3900 + 899, d: [.focusMode(shortOnly: false)]) == nil)
    // Budget (30 min) is now spent: typing can no longer defer.
    XCTAssertEqual(startAt(&s, from: 4800, to: 6000, d: [.typing]) ?? -1, 4800, accuracy: 2)
  }
  func testNinetyMinuteLineStopsFocusButTypingWaits() {
    let c = cfg(95)
    var s = Scheduler(config: c)   // long due at 95 min, already past the 90-min line
    XCTAssertEqual(startAt(&s, from: 0, to: 9000, d: [.focusApp()]) ?? -1, 5700, accuracy: 2)
    var s2 = Scheduler(config: c)
    XCTAssertEqual(startAt(&s2, from: 0, to: 9000, d: [.typing, .focusApp()]) ?? -1, 5700, accuracy: 2)   // R20
  }
  func testSkipPastLineIsRefused() {
    let c = cfg(95)
    var s = Scheduler(config: c)
    let t0 = startAt(&s, from: 0, to: 9000) ?? -1
    XCTAssertEqual(s.finish(.skipped, now: t0), [])      // core refuses, not just the UI
    XCTAssertEqual(s.finish(.snoozed, now: t0), [])
    if case .onBreak(.long, _) = s.phase {} else { XCTAssertTrue(false) }
    XCTAssertEqual(s.finish(.completed, now: t0 + 300), [.recorded(.long, planned: 300, .completed), .endBreak])
    XCTAssertEqual(s.sinceLastLongBreak, 0)
  }
  func testSkipBeforeLineStillWorks() {
    var s = longOnly()
    let t0 = startAt(&s, from: 0, to: 9000) ?? -1
    XCTAssertEqual(s.finish(.skipped, now: t0), [.recorded(.long, planned: 300, .skipped), .endBreak])
    XCTAssertEqual(s.phase, .working)
  }
  // Locking mid-break (Steve's spec, round v0.2): locked time counts toward the break.
  func testLockShortlyDuringLongBreakResumesRest() {
    var s = Scheduler()
    _ = s.breakNow(.long, now: 1000)                       // 300 s break, ends at 1300
    let cmds = s.away(.locked, seconds: 10, now: 1010)
    XCTAssertEqual(cmds, [.resumeBreak(.long, remaining: 290)])
    if case .onBreak(.long, let e) = s.phase { XCTAssertEqual(e, 1300, accuracy: 0.001) } else { XCTAssertTrue(false) }
    XCTAssertEqual(s.tick(now: 1300, reasons: [], inputIdle: 10), [.recorded(.long, planned: 300, .completed), .endBreak])
    XCTAssertEqual(s.sinceLastLongBreak, 0)
  }
  func testLockThroughLongBreakCompletesIt() {
    var s = Scheduler()
    _ = s.breakNow(.long, now: 1000)
    XCTAssertEqual(s.away(.locked, seconds: 400, now: 1400), [.recorded(.long, planned: 300, .completed), .endBreak])
    XCTAssertEqual(s.phase, .working)
    XCTAssertEqual(s.sinceLastLongBreak, 0)
  }
  func testLockCannotEndForcedLongBreakEarly() {
    let c = cfg(95)
    var s = Scheduler(config: c)
    let t0 = startAt(&s, from: 0, to: 9000) ?? -1
    XCTAssertTrue(s.longMustNotDefer)
    let cmds = s.away(.locked, seconds: 10, now: t0 + 10)
    XCTAssertEqual(cmds, [.resumeBreak(.long, remaining: c.longLength - 10)])
    XCTAssertTrue(s.longMustNotDefer)                       // 10 s of lock is not a long break
  }
  func testLockDuringShortBreakResumesRest() {
    var s = Scheduler()
    _ = s.breakNow(.short, now: 0)                         // 20 s
    XCTAssertEqual(s.away(.locked, seconds: 5, now: 5), [.resumeBreak(.short, remaining: 15)])
    XCTAssertEqual(s.away(.locked, seconds: 30, now: 35), [.recorded(.short, planned: 20, .completed), .endBreak])
  }
  func testVideoBoundedByBudget() {
    var s = longOnly()
    XCTAssertEqual(startAt(&s, from: 0, to: 9000, reasons: [.video]) ?? -1, 3000 + 1800, accuracy: 2)
  }
  func testVideoStopsAtNinetyLine() {
    let c = cfg(80)
    var s = Scheduler(config: c)   // due at 80, budget would allow 110, the line stops it at 90
    XCTAssertEqual(startAt(&s, from: 0, to: 9000, reasons: [.video]) ?? -1, 5400, accuracy: 2)
  }
  func testFullscreenStopsAtNinetyLine() {
    var s = Scheduler(config: cfg(80))
    XCTAssertEqual(startAt(&s, from: 0, to: 9000, reasons: [.fullscreen]) ?? -1, 5400, accuracy: 2)
  }
  func testScreenShareKeepsWaitingThenMakeUp() {
    var s = longOnly()
    XCTAssertTrue(startAt(&s, from: 0, to: 7000, reasons: [.screenSharing]) == nil)   // past 90 min, still held
    XCTAssertEqual(s.phase, .paused(.screenSharing))
    XCTAssertEqual((startAt(&s, from: 7001, to: 9000) ?? -1) - 7001, 0, accuracy: 1)   // past the line: right away (was 180 s)
  }
  func testVideoEndMakeUpLongBreak() {
    var s = longOnly()
    _ = startAt(&s, from: 0, to: 2900)
    XCTAssertTrue(startAt(&s, from: 2901, to: 3200, reasons: [.video]) == nil)   // crosses 50 min
    XCTAssertEqual((startAt(&s, from: 3201, to: 5000) ?? -1) - 3201, 180, accuracy: 2)
  }
  func testMeetingOutranksScreenShare() {
    var s = Scheduler()
    _ = s.tick(now: 0, reasons: [.screenSharing, .meeting, .video], deferrals: [], inputIdle: 10)
    XCTAssertEqual(s.phase, .paused(.meeting))
  }
}

let t = SchedulerTests()

final class ManualPauseTests {
  /// 60 min without a long break, then 暂停提醒 1 小时: at expiry the long break starts at once
  /// and can't be deferred.
  func sixtyThenPause() -> Scheduler {
    var s = Scheduler()
    s.config.longEveryNth = 99   // only short breaks before the pause
    var t = 0.0
    while t < 3600 {
      _ = s.tick(now: t, reasons: [], inputIdle: 10)
      if case .onBreak = s.phase { _ = s.finish(.completed, now: t) }
      t += 1
    }
    while t < 7200 { s.manualPauseTick(now: t); t += 1 }
    return s
  }
  func testPauseExpiryForcesLongBreak() {
    var s = sixtyThenPause()
    XCTAssertTrue(s.sinceLastLongBreak >= 90 * 60)
    let cmds = s.manualPauseEnded(now: 7200)
    XCTAssertEqual(cmds, [.startBreak(.long, length: 300)])
    XCTAssertTrue(s.longMustNotDefer)
    XCTAssertTrue(!s.canPostpone(by: 300))
    XCTAssertEqual(s.postponeLeft, 0)
    // 暂停提醒 1 小时 is greyed while longMustNotDefer, and back once that long break ends.
    XCTAssertTrue(s.longMustNotDefer)
    _ = s.finish(.completed, now: 7200 + 300)
    XCTAssertTrue(!s.longMustNotDefer)
  }
  func testNoRemindersDuringPause() {
    var s = Scheduler()
    for t in stride(from: 0.0, to: 7200, by: 1) { s.manualPauseTick(now: t) }
    XCTAssertEqual(s.phase, .working)
  }
  /// Idle during 暂停提醒 1 小时 is not a long break either; only a lock is (Steve, 2026-10-20).
  func testIdleDuringPauseIsNotALongBreak() {
    var s = Scheduler()
    s.config.longEveryNth = 99
    var t = 0.0
    while t < 3600 {
      _ = s.tick(now: t, reasons: [], inputIdle: 10)
      if case .onBreak = s.phase { _ = s.finish(.completed, now: t) }
      t += 1
    }
    while t < 7200 { s.manualPauseTick(now: t); t += 1 }
    XCTAssertTrue(s.sinceLastLongBreak >= 90 * 60)
    XCTAssertEqual(s.manualPauseEnded(now: 7200), [.startBreak(.long, length: 300)])
  }
  func testPauseDoesNotUseDeferBudget() {
    var s = Scheduler()
    for t in stride(from: 0.0, to: 600, by: 1) { s.manualPauseTick(now: t) }
    _ = s.manualPauseEnded(now: 600)
    XCTAssertEqual(s.deferralLeft, s.config.shortDeferBudget)
  }
}
final class PersistenceTests {
  func work(_ s: inout Scheduler, from: Double, to: Double) {
    var t = from
    while t < to {
      _ = s.tick(now: t, reasons: [], inputIdle: 10)
      if case .onBreak = s.phase { _ = s.finish(.completed, now: t) }
      t += 1
    }
  }

  /// 50 min in, +5分 postponed, quit, relaunch 1 min later: both counters carry over.
  func testResumeAfterRestart() {
    var s = Scheduler()
    work(&s, from: 0, to: 1500)                 // one short break done, 25 min since long
    XCTAssertTrue(s.postpone(by: 300))
    let before = s.sinceLastLongBreak, left = s.deferralLeft, nextLeft = s.next.remaining
    let saved = s.saved(wallClock: 1_000_000)
    var r = Scheduler()
    r.restore(saved, wallClock: 1_000_000 + 10, now: 5)   // new process, new monotonic origin
    XCTAssertEqual(r.sinceLastLongBreak, before, accuracy: 0.001)
    XCTAssertEqual(r.deferralLeft, left, accuracy: 0.001)
    XCTAssertEqual(r.next.remaining, nextLeft, accuracy: 0.001)
    XCTAssertEqual(r.cycle.index, s.cycle.index)
    // Monotonic time restarts at the new origin; no jump from the old one.
    _ = r.tick(now: 6, reasons: [], inputIdle: 10)
    XCTAssertEqual(r.sinceLastLongBreak, before + 1, accuracy: 0.001)
  }

  /// Off for at least a long break: counts as one taken. Both counters reset.
  func testGapCountsAsRest() {
    var s = Scheduler()
    work(&s, from: 0, to: 1500)
    _ = s.postpone(by: 300)
    let saved = s.saved(wallClock: 1_000_000)
    var r = Scheduler()
    r.restore(saved, wallClock: 1_000_000 + 6 * 60, now: 0)   // longLength is 5 min
    XCTAssertEqual(r.sinceLastLongBreak, 0)
    XCTAssertEqual(r.deferralLeft, r.config.shortDeferBudget)
    XCTAssertEqual(r.cycle.index, 1)
    XCTAssertTrue(!r.longMustNotDefer)
    // Wall clock moved backwards: no gap, counters kept.
    var b = Scheduler()
    b.restore(saved, wallClock: 1_000_000 - 3600, now: 0)
    XCTAssertEqual(b.sinceLastLongBreak, s.sinceLastLongBreak, accuracy: 0.001)
  }

  /// Past the 90-minute line (and after skipping past it): a quick restart does not clear it.
  func testMustNotDeferSurvivesRestart() {
    var s = ManualPauseTests().sixtyThenPause()       // 120 min since the last long break
    XCTAssertTrue(s.longMustNotDefer)
    var r = Scheduler()
    r.restore(s.saved(wallClock: 500), wallClock: 560, now: 0)
    XCTAssertTrue(r.longMustNotDefer)
    XCTAssertEqual(r.postponeLeft, 0)
    // Skip refused past the line, and still binding after a restart.
    _ = s.manualPauseEnded(now: 7200)
    XCTAssertEqual(s.finish(.skipped, now: 7210), [])   // refused past the line
    var q = Scheduler()
    q.restore(s.saved(wallClock: 900), wallClock: 930, now: 0)
    XCTAssertTrue(q.longMustNotDefer)
  }
}

let mp = ManualPauseTests()
let dt = DeferralTests()
let st = ScheduleTests()

final class PauseCapTests {
  func testVideoDroppedAfterTwoHours() {
    var c = PauseCap()
    XCTAssertEqual(c.filter([.video], now: 0), [.video])
    XCTAssertEqual(c.filter([.video], now: 7199), [.video])
    XCTAssertEqual(c.filter([.video], now: 7200), [])
    XCTAssertEqual(c.filter([.video, .fullscreen], now: 7300), [.fullscreen])   // fullscreen has its own clock
    XCTAssertEqual(c.filter([], now: 7400), [])
    XCTAssertEqual(c.filter([.video], now: 7401), [.video])                     // fresh signal
  }
  func testMeetingKeptAfterRecheck() {
    var c = PauseCap()
    XCTAssertEqual(c.filter([.meeting, .screenSharing], now: 0), [.meeting, .screenSharing])
    XCTAssertEqual(c.filter([.meeting, .screenSharing], now: 7200), [.meeting, .screenSharing])
    XCTAssertEqual(c.filter([.meeting], now: 20000), [.meeting])
    XCTAssertEqual(c.filter([.outsideHours], now: 99999), [.outsideHours])
  }
  func testOutsideHoursNeverCapped() {
    var c = PauseCap()
    XCTAssertEqual(c.filter([.outsideHours], now: 0), [.outsideHours])
    XCTAssertEqual(c.filter([.outsideHours], now: 50000), [.outsideHours])
  }
  func testFullscreenDroppedAfterTwoHours() {
    var c = PauseCap()
    XCTAssertEqual(c.filter([.fullscreen], now: 0), [.fullscreen])
    XCTAssertEqual(c.filter([.fullscreen], now: 7200), [])
  }
}
let pt = PersistenceTests()
let pc = PauseCapTests()
func testVideoSignalOnlyPlayback() {
  XCTAssertTrue(VideoSignal.isPlayback(type: "NoDisplaySleepAssertion", name: "Video Wake Lock"))
  XCTAssertTrue(!VideoSignal.isPlayback(type: "NoDisplaySleepAssertion", name: "Capturing"))   // fcBowena 2026-10-20
  XCTAssertTrue(VideoSignal.isPlayback(type: "PreventUserIdleDisplaySleep", name: "com.apple.WebCore: HTMLMediaElement playback"))   // Safari, macBowena 2026-10-27
  XCTAssertTrue(!VideoSignal.isPlayback(type: "PreventUserIdleDisplaySleep", name: "IINA playback is in progress"))   // held for audio-only files too, macBowena 2026-10-27
  XCTAssertTrue(VideoSignal.isPlayback(type: "PreventUserIdleDisplaySleep", name: "VLC video playback"))
  XCTAssertTrue(!VideoSignal.isPlayback(type: "PreventUserIdleSystemSleep", name: "VLC audio playback"))
  XCTAssertTrue(!VideoSignal.isPlayback(type: "PreventUserIdleDisplaySleep", name: "VLC audio playback"))
  XCTAssertTrue(VideoSignal.isPlayback(type: "PreventUserIdleDisplaySleep", name: "io.mpv.video_playing_back"))
  XCTAssertTrue(!VideoSignal.isPlayback(type: "PreventUserIdleDisplaySleep", name: "Ongoing A/V conference"))                       // a call, not video
  XCTAssertTrue(!VideoSignal.isPlayback(type: "PreventUserIdleDisplaySleep", name: "AlDente-Pro"))
  XCTAssertTrue(!VideoSignal.isPlayback(type: "PreventUserIdleSystemSleep", name: "Video Wake Lock"))
  XCTAssertTrue(!VideoSignal.isPlayback(type: "NoDisplaySleepAssertion", name: nil))
}

/// No app list: whoever is in front and holds "Video Wake Lock" is playing video; "Capturing" never is.
func testVideoFrontAppAnyApp() {
  let front: Int32 = 100
  func belongs(_ pid: Int32) -> Bool { pid == front || pid == 101 }          // 101: a helper of the front app
  func plays(_ hs: [VideoSignal.Holder]) -> Bool { VideoSignal.frontIsPlaying(hs, belongsToFront: belongs) }
  let wake = "Video Wake Lock", t = "NoDisplaySleepAssertion"
  XCTAssertTrue(plays([.init(pid: front, type: t, name: wake)]))               // an app that is on no list (Aside)
  XCTAssertTrue(plays([.init(pid: 101, type: t, name: wake)]))                 // its helper process
  XCTAssertTrue(!plays([.init(pid: front, type: t, name: "Capturing")]))
  XCTAssertTrue(!plays([.init(pid: 200, type: t, name: wake)]))                // a background app plays, not the front one
  XCTAssertTrue(plays([.init(pid: 200, type: t, name: wake), .init(pid: 101, type: t, name: wake)]))
}

func testStatusPrefersSource() {
  XCTAssertEqual(StatusPick.line(source: "暂停中：正在看视频", autoStatus: "已暂停：Safari 正在播放视频", reason: "x"), "暂停中：正在看视频")
  XCTAssertEqual(StatusPick.line(source: nil, autoStatus: "已推迟：Xcode 在前台", reason: "x"), "已推迟：Xcode 在前台")
  XCTAssertEqual(StatusPick.line(source: nil, autoStatus: nil, reason: "已暂停：正在开会"), "已暂停：正在开会")
}

// Break stats: one row per break, decided in the scheduler so every way a break ends is covered.
func recs(_ c: [Command]) -> [Command] { c.filter { if case .recorded = $0 { return true }; return false } }
func testStatsSnoozeRecordsOnce() {
  var s = Scheduler()
  _ = s.breakNow(.long, now: 0)
  XCTAssertEqual(recs(s.finish(.snoozed, now: 1)), [])
  _ = s.breakNow(.long, now: 2); XCTAssertEqual(recs(s.finish(.snoozed, now: 3)), [])
  _ = s.breakNow(.long, now: 4)
  XCTAssertEqual(recs(s.finish(.snoozed, now: 5)), [.recorded(.long, planned: 300, .skipped)])
}
func testStatsDays() {
  var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/New_York")!
  func d(_ s: String) -> Date { let f = ISO8601DateFormatter(); f.timeZone = cal.timeZone; f.formatOptions = [.withInternetDateTime]; return f.date(from: s)! }
  let rows = [
    BreakRecord(start: d("2026-03-07T23:58:00-05:00"), kind: .short, planned: 20, result: .completed),   // ends after midnight
    BreakRecord(start: d("2026-03-08T10:00:00-04:00"), kind: .long, planned: 300, result: .completed),
    BreakRecord(start: d("2026-03-08T11:00:00-04:00"), kind: .short, planned: 20, result: .skipped),
    BreakRecord(start: d("2026-02-01T10:00:00-05:00"), kind: .short, planned: 20, result: .completed),   // outside the window
  ]
  let days = Stats.days(rows, endingAt: d("2026-03-09T09:00:00-04:00"), count: 7, calendar: cal)
  XCTAssertEqual(days.count, 7)
  XCTAssertEqual(Set(days.map(\.day)).count, 7)   // DST day (Mar 8) is one row
  XCTAssertEqual(days[4].taken, 1); XCTAssertEqual(days[4].seconds, 20, accuracy: 0.1)   // Mar 7
  XCTAssertEqual(days[5].taken, 1); XCTAssertEqual(days[5].skipped, 1); XCTAssertEqual(days[5].seconds, 300, accuracy: 0.1)
  XCTAssertEqual(days[6].taken + days[6].skipped, 0)   // today, nothing yet
  XCTAssertEqual(days[0].day, cal.startOfDay(for: d("2026-03-03T12:00:00-05:00")))
}

func testWorkIdleEndsAtLastInput() {
  var w = WorkClock()
  XCTAssertTrue(w.update(now: 0, counting: true, inputIdle: 0, idleLimit: 300) == nil)
  XCTAssertTrue(w.update(now: 1000, counting: true, inputIdle: 299, idleLimit: 300) == nil)   // under the line: still work
  let s = w.update(now: 1001, counting: true, inputIdle: 300, idleLimit: 300)
  XCTAssertEqual(s?.start ?? -1, 0, accuracy: 0.01); XCTAssertEqual(s?.end ?? -1, 701, accuracy: 0.01)   // ends at last input
  XCTAssertTrue(w.update(now: 1500, counting: true, inputIdle: 800, idleLimit: 300) == nil)   // still away: nothing open
  XCTAssertTrue(w.openedAt == nil)
  _ = w.update(now: 1501, counting: true, inputIdle: 0, idleLimit: 300)
  XCTAssertEqual(w.openedAt ?? -1, 1501, accuracy: 0.01)
}
func testWorkStopsDuringBreak() {
  var w = WorkClock()
  _ = w.update(now: 0, counting: true, inputIdle: 0, idleLimit: 300)
  let s = w.update(now: 1200, counting: false, inputIdle: 1, idleLimit: 300)   // break screen up
  XCTAssertEqual(s?.end ?? -1, 1200, accuracy: 0.01)
  XCTAssertTrue(w.update(now: 1220, counting: false, inputIdle: 0, idleLimit: 300) == nil)
  _ = w.update(now: 1221, counting: true, inputIdle: 0, idleLimit: 300)
  XCTAssertEqual(w.openedAt ?? -1, 1221, accuracy: 0.01)
}
func testWorkSplitsAtMidnight() {
  var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
  let f = ISO8601DateFormatter()
  let w = WorkSpan(start: f.date(from: "2026-10-18T23:30:00+08:00")!, end: f.date(from: "2026-10-19T00:45:00+08:00")!)
  let days = Stats.days([], work: [w], endingAt: f.date(from: "2026-10-19T12:00:00+08:00")!, count: 2, calendar: cal)
  XCTAssertEqual(days[0].work, 30 * 60, accuracy: 0.1); XCTAssertEqual(days[1].work, 45 * 60, accuracy: 0.1)
}

func testWorkMeetingIgnoresIdle() {
  var w = WorkClock()
  _ = w.update(now: 0, counting: true, holding: true, inputIdle: 0, idleLimit: 300)
  XCTAssertTrue(w.update(now: 3600, counting: true, holding: true, inputIdle: 3600, idleLimit: 300) == nil)   // hands off, still in the call
  let s = w.close(at: 3600)   // lock
  XCTAssertEqual(s?.end ?? -1, 3600, accuracy: 0.01)
}

// Acceptance list, spec v2 §10 (/workspace/pausa-stats/spec.md). Numbers are the spec's.
// 9 (kill -9 recovery), 25, 26, 28, 29, 31–35 are UI or app-target checks, done by hand on macBowena.
enum Accept {
  static let tp: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Taipei")!; return c }()
  static func at(_ d: Int, _ h: Int, _ m: Int = 0, _ s: Int = 0) -> Date {
    tp.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m, second: s))!
  }
  /// Drive a WorkClock once a second over [from, to) and sum the closed spans.
  static func workSeconds(from: Double, to: Double, step: (Double) -> (counting: Bool, holding: Bool, idle: Double)) -> Double {
    var w = WorkClock(), total = 0.0, t = from
    while t < to {
      let x = step(t)
      if let s = w.update(now: t, counting: x.counting, holding: x.holding, inputIdle: x.idle, idleLimit: Config().longLength) { total += s.end - s.start }
      t += 1
    }
    if let s = w.close(at: to) { total += s.end - s.start }
    return total
  }
  static func records(_ cmds: [Command], start: Date) -> [BreakRecord] {
    cmds.compactMap { if case .recorded(let k, let p, let r) = $0 { return BreakRecord(start: start, kind: k, planned: p, result: r) }; return nil }
  }
}

func testAccept1MidnightSplit() {
  let w = WorkSpan(start: Accept.at(18, 22), end: Accept.at(19, 2))
  let d = Stats.days([], work: [w], endingAt: Accept.at(19, 12), count: 2, calendar: Accept.tp)
  XCTAssertEqual(d[0].work, 7200, accuracy: 0.1); XCTAssertEqual(d[1].work, 7200, accuracy: 0.1)
}
func testAccept2IdleEndsAtLastInput() {
  var w = WorkClock()
  _ = w.update(now: 0, counting: true, inputIdle: 0, idleLimit: 300)          // 09:00
  let s = w.update(now: 3900, counting: true, inputIdle: 300, idleLimit: 300) // 10:05, last input 10:00
  XCTAssertEqual(s?.end ?? -1, 3600, accuracy: 0.01)
}
func testAccept3BreakNotWork() {
  var s = Scheduler()
  let total = Accept.workSeconds(from: 0, to: 3600) { t in
    if t == 1000 { _ = s.breakNow(.long, now: t) }
    if t == 1300 { _ = s.finish(.completed, now: t) }
    if case .onBreak = s.phase { return (false, false, 0) }
    return (true, false, 0)
  }
  XCTAssertEqual(total, 3300, accuracy: 1)
}
func testAccept4MeetingIgnoresIdle() {
  XCTAssertEqual(Accept.workSeconds(from: 0, to: 3600) { t in (true, true, t) }, 3600, accuracy: 1)
}
func testAccept5LockNotWork() {
  // Locked 600..<1800: AppController closes the span at the lock (handleAway(.start)) and ticks stop.
  XCTAssertEqual(Accept.workSeconds(from: 0, to: 3600) { t in (!(600..<1800).contains(t), false, 0) }, 2400, accuracy: 1)
}
func testAccept6ActiveAndQuietHours() {
  let all = Set(1...7)
  var sch = PausaSchedule(enabled: true, rules: [PausaWindow(start: ClockTime(9), end: ClockTime(18), weekdays: all)])
  sch.exclude = HoursSet(rules: [PausaWindow(start: ClockTime(12), end: ClockTime(13), weekdays: all)])
  let day0 = Accept.at(19, 0).timeIntervalSince1970
  func used(_ s: PausaSchedule) -> Double {
    var total = 0.0
    for m in 0..<1440 where isActive(s, at: Date(timeIntervalSince1970: day0 + Double(m * 60)), cal: Accept.tp) { total += 60 }
    return total
  }
  XCTAssertEqual(used(sch), 8 * 3600, accuracy: 0.1)
  sch.enabled = false
  XCTAssertEqual(used(sch), 24 * 3600, accuracy: 0.1)
}
func testAccept7MeetingAfterHours() {
  let sch = PausaSchedule(enabled: true, rules: [PausaWindow(start: ClockTime(9), end: ClockTime(18), weekdays: Set(1...7))])
  let t0 = Accept.at(19, 18, 30).timeIntervalSince1970
  let total = Accept.workSeconds(from: t0, to: t0 + 3600) { t in
    (isActive(sch, at: Date(timeIntervalSince1970: t), cal: Accept.tp), true, 0)   // in a meeting, at the Mac
  }
  XCTAssertEqual(total, 0, accuracy: 0.1)
}
func testAccept8ManualPauseIsWork() {
  // 暂停 1 小时: AppController passes counting = in hours, holding = false.
  var s = Scheduler()
  let total = Accept.workSeconds(from: 0, to: 3600) { t in s.manualPauseTick(now: t); return (true, false, 1) }
  XCTAssertEqual(total, 3600, accuracy: 1)
}
func testAccept10ShortCompletes() {
  var s = Scheduler(); var out: [Command] = []
  var t = 0.0
  while t <= 1300 { out += s.tick(now: t, reasons: [], inputIdle: 10); t += 1 }
  let d = Stats.days(Accept.records(out, start: Accept.at(19, 10)), endingAt: Accept.at(19, 12), count: 1, calendar: Accept.tp)
  XCTAssertEqual(d[0].taken, 1); XCTAssertEqual(d[0].seconds, 20, accuracy: 0.1)
}
func testAccept11LockThroughLong() {
  var s = Scheduler()
  _ = s.breakNow(.long, now: 1000)
  XCTAssertEqual(Accept.records(s.away(.locked, seconds: 360, now: 1360), start: Accept.at(19, 10)),
                 [BreakRecord(start: Accept.at(19, 10), kind: .long, planned: 300, result: .completed)])
}
func testAccept12SkipAddsNoTime() {
  var s = Scheduler()
  _ = s.breakNow(.short, now: 0)
  let d = Stats.days(Accept.records(s.finish(.skipped, now: 5), start: Accept.at(19, 10)), endingAt: Accept.at(19, 12), count: 1, calendar: Accept.tp)
  XCTAssertEqual(d[0].skipped, 1); XCTAssertEqual(d[0].taken, 0); XCTAssertEqual(d[0].seconds, 0, accuracy: 0.1)
}
func testAccept13SnoozeThenComplete() {
  var s = Scheduler(); var out: [Command] = []
  _ = s.breakNow(.long, now: 0)
  out += s.finish(.snoozed, now: 1)
  XCTAssertEqual(Accept.records(out, start: Date()).count, 0)
  var t = 2.0
  while t <= 2000 { out += s.tick(now: t, reasons: [], inputIdle: 10); if case .onBreak = s.phase { break }; t += 1 }
  out += s.finish(.completed, now: t + 300)
  let r = Accept.records(out, start: Date())
  XCTAssertEqual(r.count, 1); XCTAssertEqual(r.first?.result, .completed)
}
func testAccept14MeetingNoBreakRows() {
  var s = Scheduler(); var out: [Command] = []
  var t = 0.0
  while t <= 7200 { out += s.tick(now: t, reasons: [.meeting], inputIdle: 600); t += 1 }
  XCTAssertEqual(Accept.records(out, start: Date()).count, 0)
}
func testAccept15BreakBelongsToStartDay() {
  let r = BreakRecord(start: Accept.at(18, 23, 59, 50), kind: .short, planned: 20, result: .completed)
  let d = Stats.days([r], endingAt: Accept.at(19, 12), count: 2, calendar: Accept.tp)
  XCTAssertEqual(d[0].taken, 1); XCTAssertEqual(d[1].taken, 0)
}
func testAccept16BarProportional() {
  let a = StatsChart.barHeight(work: 6 * 3600 + 20 * 60, longest: 7 * 3600 + 40 * 60)
  let b = StatsChart.barHeight(work: 7 * 3600 + 40 * 60, longest: 7 * 3600 + 40 * 60)
  XCTAssertEqual(a, b * (380.0 / 460.0), accuracy: 1)
  XCTAssertEqual(b, 230, accuracy: 0.01)   // 7 h 40 min is under the 8 h floor (item 17), so not 240
  XCTAssertEqual(StatsChart.barHeight(work: 9 * 3600, longest: 9 * 3600), 240, accuracy: 0.01)
  XCTAssertEqual(StatsChart.barHeight(work: 0, longest: 0), 0, accuracy: 0.001)
}
func testAccept17ScaleFloor() {
  XCTAssertEqual(StatsChart.barHeight(work: 85 * 60, longest: 85 * 60), 240 * 85 / 480, accuracy: 0.5)
}
func testAccept18FullDay() {
  XCTAssertEqual(StatsChart.barHeight(work: 24 * 3600, longest: 24 * 3600), 240, accuracy: 0.01)
  XCTAssertEqual(StatsChart.barHeight(work: 16 * 3600, longest: 24 * 3600), 160, accuracy: 0.01)
  XCTAssertEqual(StatsChart.label(24 * 3600), .hours("24.0"))
}
func testAccept19ScaleCeiling() {
  let w = WorkSpan(start: Accept.at(16, 12), end: Accept.at(19, 12))   // three days on
  let d = Stats.days([], work: [w], endingAt: Accept.at(19, 12), count: 4, calendar: Accept.tp)
  let expect: [Double] = [43200, 86400, 86400, 43200]
  XCTAssertEqual(d.map(\.work), expect)
  let longest = d.map(\.work).max()!
  XCTAssertTrue(d.allSatisfy { StatsChart.barHeight(work: $0.work, longest: longest) <= 240 })
  XCTAssertEqual(StatsChart.barHeight(work: 25 * 3600, longest: 25 * 3600), 240, accuracy: 0.01)   // DST fall-back day
}
/// One working day from 00:00: `n` completed breaks spread evenly over `work` seconds, plus `skips`.
func acceptDay(work: Double, breaks n: Int, skips: Int = 0) -> DayStats {
  let start = Accept.at(19, 0)
  let w = WorkSpan(start: start, end: start.addingTimeInterval(work))
  var r = (1...max(1, n)).prefix(n).map { k in
    BreakRecord(start: start.addingTimeInterval(work * Double(k) / Double(n + 1)), kind: .short, planned: 20, result: .completed)
  }
  r += (0..<skips).map { _ in BreakRecord(start: start.addingTimeInterval(60), kind: .short, planned: 20, result: .skipped) }
  return Stats.days(r, work: [w], endingAt: Accept.at(19, 23), count: 1, calendar: Accept.tp)[0]
}
func testAccept20TypicalGapSpacing() {
  let work = 7 * 3600 + 40 * 60.0
  let d = acceptDay(work: work, breaks: 20)
  let ys = d.gaps.map { StatsChart.barHeight(work: $0, longest: work) }
  XCTAssertTrue(zip(ys.dropFirst(), ys).allSatisfy { $0 - $1 > 1 })        // no gap touches the next
  let solid = (StatsChart.barHeight(work: work, longest: work) - Double(ys.count)) / Double(ys.count + 1)
  XCTAssertEqual(d.gaps.count, 20)
  XCTAssertTrue(solid >= 10 - 1e-9)   // 230 pt bar (7 h 40 min on the 8 h axis): exactly 10.0 pt
}
func testAccept21GapPerBreak() {
  XCTAssertEqual(acceptDay(work: 8 * 3600, breaks: 13).gaps.count, 13)
  XCTAssertEqual(acceptDay(work: 24 * 3600, breaks: 70).gaps.count, 70)
}
func testAccept22GapPosition() {
  let start = Accept.at(19, 9)
  let w = [WorkSpan(start: start, end: Accept.at(19, 11)), WorkSpan(start: Accept.at(19, 11, 0, 20), end: Accept.at(19, 16))]
  let r = [BreakRecord(start: Accept.at(19, 11), kind: .short, planned: 20, result: .completed)]
  let d = Stats.days(r, work: w, endingAt: Accept.at(19, 23), count: 1, calendar: Accept.tp)[0]
  XCTAssertEqual(d.gaps, [7200])
  XCTAssertEqual(StatsChart.barHeight(work: d.gaps[0], longest: d.work), 240 * 2 / 8, accuracy: 1)   // 2 h on the 8 h axis
}
func testAccept23SkipNoGap() {
  let d = acceptDay(work: 8 * 3600, breaks: 13, skips: 1)
  XCTAssertEqual(d.gaps.count, 13); XCTAssertEqual(d.skipped, 1)
}
func testAccept24BarLabels() {
  XCTAssertEqual(StatsChart.label(6 * 3600 + 20 * 60), .hours("6.3"))
  XCTAssertEqual(StatsChart.label(2 * 3600), .hours("2.0"))
  XCTAssertEqual(StatsChart.label(45 * 60), .minutes(45))
  XCTAssertEqual(StatsChart.label(24 * 3600), .hours("24.0"))
  XCTAssertEqual(StatsChart.label(6 * 3600 + 20 * 60, locale: Locale(identifier: "fr")), .hours("6,3"))
}
func testAccept27EmptyDay() {
  let d = Stats.days([], endingAt: Accept.at(19, 12), count: 1, calendar: Accept.tp)[0]
  XCTAssertTrue(StatsChart.label(d.work) == nil); XCTAssertEqual(d.taken, 0); XCTAssertTrue(d.gaps.isEmpty)
}
func testAccept30KeepThirtyDays() {
  let cut = Stats.keepFrom(now: Accept.at(19, 12), days: 30, calendar: Accept.tp)
  XCTAssertEqual(cut, Accept.tp.date(from: DateComponents(year: 2026, month: 9, day: 20))!)   // today and the 29 before
}
func testDurationParts() {   // spec §5.4
  XCTAssertEqual(DurationParts(0), .minutes(0)); XCTAssertEqual(DurationParts(40), .seconds(40))
  XCTAssertEqual(DurationParts(18 * 60 + 59), .minutes(18))
  XCTAssertEqual(DurationParts(4 * 3600 + 12 * 60), .hours(4, minutes: 12)); XCTAssertEqual(DurationParts(7200), .hours(2, minutes: 0))
}

/// Mic / camera -> CallHold -> PauseCap -> Scheduler, wired the way PauseDetector + AppController do.
final class MicTests {
  struct Run { var starts: [Double] = []; var startsWithMicOn = 0; var holdTicks = 0; var reasons: Set<PauseReason> = [] }
  func run(_ s: inout Scheduler, from: Double, to: Double, mic on: (Double) -> Bool,
           app: (Double) -> Bool = { _ in false }, cam: (Double) -> Bool = { _ in false }) -> Run {
    var h = CallHold(), cap = PauseCap(), r = Run(), t = from
    while t <= to {
      let st = h.update(micOn: on(t) || app(t), meetingAppMic: app(t), camera: cam(t), now: t)
      let rs = cap.filter(st.reason.map { [$0] } ?? [], now: t)
      for c in s.tick(now: t, reasons: rs, deferrals: st.micPending ? [.microphone] : [], inputIdle: 10) {
        if case .startBreak = c { r.starts.append(t); if on(t) || app(t) { r.startsWithMicOn += 1 } }
      }
      if s.phase == .paused(.meeting) || s.phase == .paused(.micInUse) { r.holdTicks += 1 }
      if let x = st.reason { r.reasons.insert(x) }
      t += 1
    }
    return r
  }
  /// Typeless-style 20 s bursts every minute for 2 h: never a hold, breaks keep coming, none while
  /// the mic is on, each at most one burst late.
  func testDictationBurstsStillGetBreaks() {
    var s = Scheduler()
    let r = run(&s, from: 0, to: 7200, mic: { $0.truncatingRemainder(dividingBy: 60) < 20 })
    XCTAssertEqual(r.holdTicks, 0); XCTAssertEqual(r.reasons, []); XCTAssertEqual(r.startsWithMicOn, 0)
    XCTAssertTrue(r.starts.count >= 5)
    XCTAssertEqual(r.starts.first ?? -1, 1220, accuracy: 1)   // due at 1200, burst 1200-1219
  }
  /// Break due 10 s into a 20 s burst starts the tick the mic stops; no 「正在使用麦克风」.
  func testBreakDueDuringBurstFiresAfter() {
    var s = Scheduler()
    let r = run(&s, from: 0, to: 1300, mic: { $0 >= 1190 && $0 < 1210 })
    XCTAssertEqual(r.starts, [1210]); XCTAssertEqual(r.holdTicks, 0)
  }
  /// Past the 90-minute line nothing defers the long break except the mic's one-minute question: a
  /// call starting just then gets no break on screen; a 20 s burst there delays it to the burst's end.
  func testMicFirmPastNinetyLine() {
    var cf = Config(); cf.breakEvery = 95 * 60; cf.longEveryNth = 1
    var s = Scheduler(config: cf)
    let r = run(&s, from: 0, to: 5800, mic: { $0 >= 5690 })
    XCTAssertEqual(r.starts, []); XCTAssertTrue(r.holdTicks > 0)
    var s2 = Scheduler(config: cf)
    XCTAssertEqual(run(&s2, from: 0, to: 5800, mic: { $0 >= 5690 && $0 < 5710 }).starts, [5710])
  }
  /// 100-minute meeting crossing the 90-minute line: no break during it or its grace; the long break
  /// the tick the hold ends, no heads-up wait, the 90-minute clock not restarted.
  func testNinetyLineFiresRightAfterMeeting() {
    var s = Scheduler()
    let r = run(&s, from: 0, to: 6778, mic: { $0 >= 600 && $0 < 6660 })   // last mic tick 6659, grace to 6778
    XCTAssertEqual(r.starts, []); XCTAssertEqual(s.phase, .paused(.micInUse))
    XCTAssertTrue(s.sinceLastLongBreak >= 6600)
    XCTAssertEqual(s.tick(now: 6779, reasons: [], deferrals: [], inputIdle: 10), [.startBreak(.long, length: 300)])
  }
  /// Mic alone: pending until 60 s unbroken, then .micInUse, 2 min grace; dictation leaves no tail.
  func testMicAloneAfter60s() {
    var h = CallHold()
    var st: [CallHold.State] = []
    for t in 0...61 { st.append(h.update(micOn: true, meetingAppMic: false, camera: false, now: Double(t))) }
    XCTAssertEqual(st[59], CallHold.State(reason: nil, micPending: true))
    XCTAssertEqual(st[60].reason, .micInUse); XCTAssertTrue(!st[60].micPending)
    XCTAssertEqual(h.update(micOn: false, meetingAppMic: false, camera: false, now: 61 + 119).reason, .micInUse)
    XCTAssertEqual(h.update(micOn: false, meetingAppMic: false, camera: false, now: 61 + 120).reason, nil)
    var d = CallHold()
    for t in 0..<20 { _ = d.update(micOn: true, meetingAppMic: false, camera: false, now: Double(t)) }
    XCTAssertEqual(d.update(micOn: false, meetingAppMic: false, camera: false, now: 20), CallHold.State(reason: nil, micPending: false))
  }
  /// Camera, or a listed meeting app on the mic: .meeting at once.
  func testCameraAndMeetingAppImmediate() {
    var h = CallHold()
    XCTAssertEqual(h.update(micOn: false, meetingAppMic: false, camera: true, now: 0).reason, .meeting)
    var z = CallHold()
    XCTAssertEqual(z.update(micOn: true, meetingAppMic: true, camera: false, now: 0), CallHold.State(reason: .meeting, micPending: false))
    var s = Scheduler()   // break due at 1200, Zoom joins at 1195: held, no break
    let r = run(&s, from: 0, to: 1300, mic: { _ in false }, app: { $0 >= 1195 })
    XCTAssertEqual(r.starts, []); XCTAssertEqual(s.phase, .paused(.meeting))
  }
  /// Backstop: a background process holding the mic for 3 h gets the 2-hour recheck, so breaks come
  /// back; a camera or meeting-app call is exempt and never gets one.
  func testBackgroundMicThreeHoursGetsBreak() {
    var s = Scheduler()
    let r = run(&s, from: 0, to: 3 * 3600, mic: { _ in true })
    XCTAssertTrue(r.starts.count >= 1)
    XCTAssertTrue(r.starts.allSatisfy { $0 >= 60 + PauseCap.defaultCap })   // only after the recheck
    var z = Scheduler()
    XCTAssertEqual(run(&z, from: 0, to: 3 * 3600, mic: { _ in false }, app: { _ in true }).starts, [])
    var c = Scheduler()
    XCTAssertEqual(run(&c, from: 0, to: 3 * 3600, mic: { _ in true }, cam: { _ in true }).starts, [])
  }
}
let mt = MicTests()

/// Pre-break panel state (spec: pre-break notch panel, acceptance A1-A13). Short break due at t = 1200
/// with the default config: the 30 s warning starts at t = 1170.
final class PreBreakTests {
  func tick(_ s: inout Scheduler, _ t: Double, reasons: Set<PauseReason> = [], deferrals: [Deferral] = [],
            idle: Double = 10) -> [Command] {
    s.tick(now: t, reasons: reasons, deferrals: deferrals, inputIdle: idle)
  }
  /// A scheduler ticked once a second up to and including `t`.
  func sched(to t: Double, config: Config = Config()) -> Scheduler {
    var s = Scheduler(config: config)
    var i = 0.0
    while i <= t { _ = tick(&s, i); i += 1 }
    return s
  }

  func testCardAppearsAt30() {   // A1
    var s = sched(to: 1169)
    XCTAssertTrue(s.preBreak == nil)
    _ = tick(&s, 1170)
    XCTAssertEqual(s.preBreak?.showCard, true)
    XCTAssertEqual(s.preBreak?.secondsLeft, 30)
    XCTAssertEqual(s.preBreak?.kind, .short)
  }

  func testCountsDownEverySecond() {   // A2, A3
    var s = sched(to: 1169)
    for n in stride(from: 30, through: 1, by: -1) {
      _ = tick(&s, 1200 - Double(n))
      XCTAssertEqual(s.preBreak?.secondsLeft, n)
      XCTAssertEqual(s.preBreak?.showCard, true)
      XCTAssertEqual(s.preBreak?.showPill, n <= 10)
    }
  }

  func testStartsBreakAtZero() {   // A4
    var s = sched(to: 1199)
    let cmds = tick(&s, 1200)
    XCTAssertEqual(cmds, [.startBreak(.short, length: 20)])
    XCTAssertTrue(s.preBreak == nil)
  }

  func testTypingWaitShowsPillOnly() {   // A5
    for deferrals in [[Deferral.typing], []] {   // the typing deferral, and the fallback wait for input to stop
      var s = sched(to: 1199)
      _ = tick(&s, 1200, deferrals: deferrals, idle: 0)
      let p = s.preBreak
      XCTAssertEqual(p?.typingWait, true)
      XCTAssertEqual(p?.showCard, false)
      XCTAssertEqual(p?.showPill, true)
      XCTAssertEqual(p?.secondsLeft, 0)
      _ = tick(&s, 1201, deferrals: [], idle: 10)   // typing stopped: the break starts
      XCTAssertTrue(s.preBreak == nil)
    }
    var m = sched(to: 1199)
    _ = tick(&m, 1200, deferrals: [.microphone], idle: 10)
    XCTAssertEqual(m.preBreak?.typingWait, true)
    var f = sched(to: 1199)   // a focus app defers too, but no pill: the break is simply later
    _ = tick(&f, 1200, deferrals: [.focusApp()], idle: 10)
    XCTAssertTrue(f.preBreak == nil)
  }

  func testPauseReasonsHideIt() {   // A6
    for r in [PauseReason.meeting, .screenSharing, .micInUse, .video, .fullscreen, .outsideHours] {
      var s = sched(to: 1180)
      XCTAssertEqual(s.preBreak?.showCard, true)
      _ = tick(&s, 1181, reasons: [r])
      XCTAssertTrue(s.preBreak == nil)
    }
  }

  func testShortResumeDoesNotOpenCard() {   // A7: a card that would open with under 5 s left stays closed
    var a = sched(to: 1195)                       // 5 s left
    _ = tick(&a, 1196, reasons: [.fullscreen])
    XCTAssertTrue(a.preBreak == nil)
    _ = tick(&a, 1197)                            // back, 4 s left
    XCTAssertEqual(a.preBreak?.secondsLeft, 4)
    XCTAssertEqual(a.preBreak?.showCard, false)
    XCTAssertEqual(a.preBreak?.showPill, true)
    var b = sched(to: 1193)
    _ = tick(&b, 1194, reasons: [.fullscreen])
    _ = tick(&b, 1195)                            // back, 6 s left
    XCTAssertEqual(b.preBreak?.secondsLeft, 6)
    XCTAssertEqual(b.preBreak?.showCard, true)
    var c = sched(to: 1196)                       // already open at 4 s: stays open until 0
    XCTAssertEqual(c.preBreak?.secondsLeft, 4)
    XCTAssertEqual(c.preBreak?.showCard, true)
    _ = tick(&c, 1197)
    XCTAssertEqual(c.preBreak?.showCard, true)
  }

  func testPostponeComesBackAt30() {   // A8
    var s = sched(to: 1180)                       // 20 s left
    XCTAssertTrue(s.postpone(by: 300))
    XCTAssertTrue(s.preBreak == nil)
    var t = 1181.0, ticks = 0
    while s.preBreak == nil && t < 3000 { _ = tick(&s, t); t += 1; ticks += 1 }
    XCTAssertEqual(s.preBreak?.secondsLeft, 30)
    XCTAssertEqual(ticks, 20 + 300 - 30)
  }

  func testSnoozeUsedUp() {   // A9
    var s = sched(to: 1180)
    XCTAssertEqual(s.preBreak?.snooze, .available(minutes: 5))
    XCTAssertTrue(s.postpone(by: 300))
    var t = 1181.0
    while s.preBreak == nil { _ = tick(&s, t); t += 1 }
    XCTAssertEqual(s.preBreak?.snooze, .available(minutes: 5))
    XCTAssertTrue(s.postpone(by: 300))            // the short budget is 10 minutes: two snoozes
    while s.preBreak == nil { _ = tick(&s, t); t += 1 }
    XCTAssertEqual(s.preBreak?.snooze, .usedUp)
    XCTAssertEqual(s.preBreak?.canSkip, true)
  }

  /// 30-minute interval, long every 3rd break: the long break lands exactly on the 90-minute line.
  func testNinetyMinuteLine() {   // A10, A11
    var c = Config(); c.breakEvery = 30 * 60
    var s = Scheduler(config: c)
    var t = 0.0, longs = 0, last: PreBreakState?
    while t < 6000 && longs == 0 {
      for cmd in tick(&s, t) { if case .startBreak(.long, _) = cmd { longs += 1 } }
      if case .onBreak = s.phase, longs == 0 { _ = s.finish(.completed, now: t) }
      if case .warning(.long) = s.phase, let p = s.preBreak { last = p }
      t += 1
    }
    XCTAssertEqual(longs, 1)
    XCTAssertEqual(last?.kind, .long)
    XCTAssertEqual(last?.atHardLine, true)
    XCTAssertEqual(last?.snooze, .hidden)
    XCTAssertEqual(last?.canSkip, false)
  }

  func testLongBreakHasNoSkip() {   // A11
    var s = Scheduler()
    var t = 0.0, p: PreBreakState?
    while t < 3700 && p == nil {
      _ = tick(&s, t)
      if case .onBreak = s.phase { _ = s.finish(.completed, now: t) }
      if case .warning(.long) = s.phase { p = s.preBreak }
      t += 1
    }
    XCTAssertEqual(p?.kind, .long)
    XCTAssertEqual(p?.canSkip, false)
    XCTAssertEqual(p?.atHardLine, false)
    XCTAssertEqual(p?.snooze, .available(minutes: 5))
  }

  // Bowen 2026-10-28: the top panel and the pointer countdown are two independent switches.
  func testMaskOnlyPanel() {
    let s = sched(to: 1190).preBreak                 // 10 s left: panel and pill
    XCTAssertEqual(s?.showCard, true); XCTAssertEqual(s?.showPill, true)
    let m = s?.masked(panel: true, pointer: false)
    XCTAssertEqual(m?.showCard, true); XCTAssertEqual(m?.showPill, false)
    XCTAssertEqual(m?.secondsLeft, s?.secondsLeft)
    XCTAssertTrue(s?.masked(panel: true, pointer: true) == s)
  }

  func testMaskOnlyPointer() {
    let s = sched(to: 1190).preBreak
    let m = s?.masked(panel: false, pointer: true)
    XCTAssertEqual(m?.showCard, false); XCTAssertEqual(m?.showPill, true)
    XCTAssertEqual(m?.secondsLeft, s?.secondsLeft)
    let early = sched(to: 1175).preBreak              // 25 s left: only the panel exists yet, so nothing remains
    XCTAssertEqual(early?.showPill, false)
    XCTAssertTrue(early?.masked(panel: false, pointer: true) == nil)
  }

  func testMaskBothOff() {
    XCTAssertTrue(sched(to: 1175).preBreak?.masked(panel: false, pointer: false) == nil)
    XCTAssertTrue(sched(to: 1190).preBreak?.masked(panel: false, pointer: false) == nil)
  }

  func testSkipUpcoming() {   // A12
    var s = sched(to: 1180)
    let cmds = s.skipUpcoming(now: 1180)
    XCTAssertEqual(cmds, [.recorded(.short, planned: 20, .skipped)])
    XCTAssertEqual(s.sinceBreak, 0)
    XCTAssertEqual(s.phase, .working)
    XCTAssertTrue(s.preBreak == nil)
    XCTAssertEqual(s.next.remaining, 1200, accuracy: 0.001)
    var w = sched(to: 600)                        // not announced yet: nothing happens
    XCTAssertEqual(w.skipUpcoming(now: 600), [])
    XCTAssertEqual(w.sinceBreak, 600)
    var l = Scheduler(); var t = 0.0
    while t < 3700 {   // the long break's announcement can't be skipped
      _ = tick(&l, t)
      if case .onBreak = l.phase { _ = l.finish(.completed, now: t) }
      if case .warning(.long) = l.phase { break }
      t += 1
    }
    let before = l.sinceBreak
    XCTAssertEqual(l.skipUpcoming(now: t), [])
    XCTAssertEqual(l.sinceBreak, before)
    XCTAssertEqual(l.phase, .warning(.long))
  }

  func testNoPanelOnBreakOrBreakNow() {
    var s = sched(to: 1180)
    _ = s.breakNow(.short, now: 1180)
    XCTAssertTrue(s.preBreak == nil)
  }
}
let pb = PreBreakTests()

let cases: [(String, () -> Void)] = [
 ("shortBreakAt20Min", t.testShortBreakAt20Min), ("everyThirdIsLong", t.testEveryThirdBreakIsLong), ("cycle.skipCounts", t.testSkippedBreakCountsTowardCycle), ("cycle.meetingCountsWhenLongNext", t.testMeetingCountsWhenLongIsNext), ("cycle.migration", t.testLegacyLongEveryMigration), ("cycle.ninetyCap", t.testCycleNinetyCap), ("hardLine.setting", t.testHardLineSetting), ("hardLine.sixtyMeeting", t.testSixtyLineMeetingEndsIntoLongBreak), ("cycle.countConversion", t.testNthCountConversion), ("menubar.ringStep", t.testRingStep),
 ("pausedTimeDoesNotCount", t.testPausedTimeDoesNotCount), ("meetingOutranksFullscreen", t.testMeetingOutranksFullscreen),
 ("meeting.longEarns", t.testLongMeetingEarnsLongBreak), ("meeting.nearLong", t.testShortMeetingNearLongEarnsLongBreak), ("meeting.resumes", t.testShortMeetingResumes),
 ("waitsForTypingButNotForever", t.testWaitsForTypingButNotForever), ("lidClosedHourDoesNotFireStaleBreak", t.testLidClosedHourDoesNotFireStaleBreak),
 ("idle.notALongBreak", t.testIdleIsNotALongBreak), ("skip.longComesBackNext", t.testSkippedLongComesBackNext), ("skip.stopsAtNinety", t.testRepeatedSkipsStopAtNinety), ("skip.snoozedOutStillOwed", t.testSnoozedOutLongStillOwed), ("readingWithoutInputStillGetsShortBreak", t.testReadingWithoutInputStillGetsShortBreak), ("snoozeLimit", t.testSnoozeLimit), ("breakEndsOnItsOwn", t.testBreakEndsOnItsOwn),
 ("schedule.crossMidnight", st.testCrossMidnight), ("schedule.timeZoneSwitch", st.testTimeZoneSwitch),
 ("schedule.dstStart", st.testDSTStart), ("schedule.dstEnd", st.testDSTEnd), ("schedule.overrideOff", st.testOverrideOff),
 ("schedule.overrideWindows", st.testOverrideWindows), ("schedule.disabledRule", st.testDisabledRule),
 ("schedule.scheduleDisabled", st.testScheduleDisabled), ("schedule.firstWeekdayIrrelevant", st.testFirstWeekdayIrrelevant),
 ("schedule.nextStart", st.testNextStart),
 ("hours.pauseThenFresh", st.testSchedulerPausesOutsideHoursAndStartsFresh), ("hours.windowEnd", st.testWindowEndPausesMidCount),
 ("hours.meetingOutranks", st.testMeetingOutranksOutsideHours), ("hours.manualBreak", st.testManualBreakOutsideHours),
 ("schedule.nextChange", st.testNextChange),
 ("defer.typing30s", dt.testTypingCappedAt30s), ("typing.graceBudget", dt.testTypingGraceUsesBudget),
 ("typing.budgetSpent", dt.testTypingGraceStopsWhenBudgetSpent), ("typing.forcedLong", dt.testTypingNeverDelaysForcedLong), ("defer.shortBudget", dt.testShortBudgetCapsFocusApp),
 ("defer.focusShortOnly", dt.testFocusModeShortOnlyDoesNotDeferLong), ("defer.concurrentOnce", dt.testSharedBudgetConcurrentCountsOnce),
 ("defer.sequential30", dt.testSharedBudgetSequentialStopsAt30), ("defer.ninetyLine", dt.testNinetyMinuteLineStopsFocusButTypingWaits),
 ("defer.skipPastLineRefused", dt.testSkipPastLineIsRefused), ("defer.skipBeforeLine", dt.testSkipBeforeLineStillWorks),
 ("lock.longResumes", dt.testLockShortlyDuringLongBreakResumesRest), ("lock.longCompletes", dt.testLockThroughLongBreakCompletesIt),
 ("lock.forcedNotEnded", dt.testLockCannotEndForcedLongBreakEarly), ("lock.shortResumes", dt.testLockDuringShortBreakResumesRest),
 ("defer.videoBudget", dt.testVideoBoundedByBudget), ("defer.videoNinety", dt.testVideoStopsAtNinetyLine), ("defer.fullscreenNinety", dt.testFullscreenStopsAtNinetyLine),
 ("defer.shareMakeUp", dt.testScreenShareKeepsWaitingThenMakeUp), ("defer.videoMakeUp", dt.testVideoEndMakeUpLongBreak),
 ("defer.priority", dt.testMeetingOutranksScreenShare), ("postpone.shortBudget", dt.testMenuPostponeShortBudget), ("postpone.ninety", dt.testMenuPostponeLongStopsAtNinety), ("schedule.migrationV1", st.testMigrationV1), ("schedule.dayKinds", st.testDayKinds), ("schedule.workdayUnion", st.testWorkdayUnionsWeekdayRules),
 ("pause.expiryForcesLong", mp.testPauseExpiryForcesLongBreak), ("pause.noReminders", mp.testNoRemindersDuringPause),
 ("pause.idleNotLongBreak", mp.testIdleDuringPauseIsNotALongBreak), ("pause.noDeferBudget", mp.testPauseDoesNotUseDeferBudget),
 ("persist.resume", pt.testResumeAfterRestart), ("persist.gapIsRest", pt.testGapCountsAsRest), ("persist.mustNotDefer", pt.testMustNotDeferSurvivesRestart), ("cap.videoDropped", pc.testVideoDroppedAfterTwoHours), ("cap.meetingKept", pc.testMeetingKeptAfterRecheck), ("cap.outsideHours", pc.testOutsideHoursNeverCapped), ("cap.fullscreenDropped", pc.testFullscreenDroppedAfterTwoHours), ("video.onlyPlayback", testVideoSignalOnlyPlayback), ("video.frontAppAnyApp", testVideoFrontAppAnyApp), ("status.prefersSource", testStatusPrefersSource), ("stats.snoozeOnce", testStatsSnoozeRecordsOnce), ("stats.days", testStatsDays), ("work.idleEndsAtLastInput", testWorkIdleEndsAtLastInput), ("work.stopsDuringBreak", testWorkStopsDuringBreak), ("work.splitsAtMidnight", testWorkSplitsAtMidnight), ("work.meetingIgnoresIdle", testWorkMeetingIgnoresIdle), ("accept.1", testAccept1MidnightSplit), ("accept.2", testAccept2IdleEndsAtLastInput), ("accept.3", testAccept3BreakNotWork), ("accept.4", testAccept4MeetingIgnoresIdle), ("accept.5", testAccept5LockNotWork), ("accept.6", testAccept6ActiveAndQuietHours), ("accept.7", testAccept7MeetingAfterHours), ("accept.8", testAccept8ManualPauseIsWork), ("accept.10", testAccept10ShortCompletes), ("accept.11", testAccept11LockThroughLong), ("accept.12", testAccept12SkipAddsNoTime), ("accept.13", testAccept13SnoozeThenComplete), ("accept.14", testAccept14MeetingNoBreakRows), ("accept.15", testAccept15BreakBelongsToStartDay), ("accept.16", testAccept16BarProportional), ("accept.17", testAccept17ScaleFloor), ("accept.18", testAccept18FullDay), ("accept.19", testAccept19ScaleCeiling), ("accept.20", testAccept20TypicalGapSpacing), ("accept.21", testAccept21GapPerBreak), ("accept.22", testAccept22GapPosition), ("accept.23", testAccept23SkipNoGap), ("accept.24", testAccept24BarLabels), ("accept.27", testAccept27EmptyDay), ("accept.30", testAccept30KeepThirtyDays), ("stats.durationParts", testDurationParts),
 ("mic.dictationStillGetsBreaks", mt.testDictationBurstsStillGetBreaks), ("mic.breakAfterBurst", mt.testBreakDueDuringBurstFiresAfter), ("mic.firmPastNinety", mt.testMicFirmPastNinetyLine), ("meeting.ninetyFiresAfter", mt.testNinetyLineFiresRightAfterMeeting), ("mic.aloneAfter60s", mt.testMicAloneAfter60s), ("mic.cameraAndMeetingAppImmediate", mt.testCameraAndMeetingAppImmediate), ("mic.backgroundThreeHoursGetsBreak", mt.testBackgroundMicThreeHoursGetsBreak),
 ("prebreak.cardAt30", pb.testCardAppearsAt30), ("prebreak.countdown", pb.testCountsDownEverySecond), ("prebreak.startsBreak", pb.testStartsBreakAtZero),
 ("prebreak.typingWait", pb.testTypingWaitShowsPillOnly), ("prebreak.pauseHides", pb.testPauseReasonsHideIt), ("prebreak.shortResume", pb.testShortResumeDoesNotOpenCard),
 ("prebreak.postpone", pb.testPostponeComesBackAt30), ("prebreak.snoozeUsedUp", pb.testSnoozeUsedUp), ("prebreak.ninetyLine", pb.testNinetyMinuteLine),
 ("prebreak.longNoSkip", pb.testLongBreakHasNoSkip), ("prebreak.skipUpcoming", pb.testSkipUpcoming), ("prebreak.maskOnlyPanel", pb.testMaskOnlyPanel), ("prebreak.maskOnlyPointer", pb.testMaskOnlyPointer), ("prebreak.maskBothOff", pb.testMaskBothOff), ("prebreak.breakNow", pb.testNoPanelOnBreakOrBreakNow)]
for (n, f) in cases { let before = failures; f(); print(failures == before ? "ok   \(n)" : "FAIL \(n)") }
print(failures == 0 ? "ALL PASS (\(cases.count))" : "\(failures) failures"); exit(failures == 0 ? 0 : 1)
