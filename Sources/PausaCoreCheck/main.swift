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
    _ = run(&s, from: 601, to: 4000, reasons: [.fullscreen])
    XCTAssertEqual(s.phase, .paused(.fullscreen))
    XCTAssertEqual(s.next.remaining, 600, accuracy: 2)
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

  func testIdleOnlyOffsetsLongBreak() {
    var s = Scheduler()
    _ = run(&s, from: 0, to: 1000)
    s.away(.idle, seconds: 600, now: 1600)
    XCTAssertEqual(s.next.kind, .short)
    XCTAssertEqual(s.next.remaining, 200, accuracy: 2)
  }

  func testReadingWithoutInputStillGetsShortBreak() {
    var s = Scheduler()
    var started: [BreakKind] = []
    var t = 0.0
    while t <= 1300 {
      if t > 100 { s.away(.idle, seconds: t - 100, now: t) }   // no input since t=100
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
    XCTAssertEqual(Config.nth(forLegacyLongEveryMin: 50, everyMin: 20), 3)   // old default → 标准
    XCTAssertEqual(Config.nth(forLegacyLongEveryMin: 45, everyMin: 20), 2)   // old 护眼优先
    XCTAssertEqual(Config.nth(forLegacyLongEveryMin: 60, everyMin: 40), 2)   // old 少打扰
    XCTAssertEqual(Config.nth(forLegacyLongEveryMin: 120, everyMin: 20), 4)  // capped at 90 min
    XCTAssertEqual(Config.nth(forLegacyLongEveryMin: 30, everyMin: 25), 2)   // never below 2
  }
  func testNthCountConversion() {
    for (n, c) in [(2, 1), (3, 2), (4, 3), (5, 4), (6, 5)] {
      XCTAssertEqual(Config.count(fromNth: n), c); XCTAssertEqual(Config.nth(fromCount: c), n)
    }
    XCTAssertEqual(Config.count(fromNth: 1), 1)                                 // never below 1
    XCTAssertTrue(Config.allows(everyMin: 45, count: 1)); XCTAssertTrue(!Config.allows(everyMin: 45, count: 2))
    XCTAssertTrue(Config.allows(everyMin: 30, count: 2)); XCTAssertTrue(!Config.allows(everyMin: 30, count: 3))
    XCTAssertTrue(Config.allows(everyMin: 15, count: 5)); XCTAssertTrue(!Config.allows(everyMin: 60, count: 1))
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
    XCTAssertTrue(Config.allows(everyMin: 20, nth: 3)); XCTAssertTrue(Config.allows(everyMin: 40, nth: 2))
    XCTAssertTrue(Config.allows(everyMin: 45, nth: 2)); XCTAssertTrue(!Config.allows(everyMin: 20, nth: 5))
    XCTAssertTrue(!Config.allows(everyMin: 60, nth: 2))
  }

  func testBreakEndsOnItsOwn() {
    var s = Scheduler()
    _ = s.breakNow(.short, now: 0)
    XCTAssertEqual(s.tick(now: 20, reasons: [], inputIdle: 10), [.endBreak])
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

  func testTypingCappedAt2Min() {
    var s = Scheduler()
    XCTAssertEqual(startAt(&s, from: 0, to: 2000, d: [.typing]) ?? -1, 1200 + 120, accuracy: 2)
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
    XCTAssertEqual(startAt(&s2, from: 0, to: 9000, d: [.typing, .focusApp()]) ?? -1, 5700 + 120, accuracy: 2)
  }
  func testSkipPastLineMeansNextLongCannotWait() {
    let c = cfg(95)
    var s = Scheduler(config: c)
    let t0 = startAt(&s, from: 0, to: 9000) ?? -1
    _ = s.finish(.skipped, now: t0)
    let t1 = startAt(&s, from: t0 + 1, to: t0 + 9000, d: [.typing, .focusApp()]) ?? -1
    XCTAssertEqual(t1 - t0, 5700, accuracy: 2)   // not even typing defers it
    _ = s.finish(.completed, now: t1)
    let t2 = startAt(&s, from: t1 + 1, to: t1 + 9000, d: [.typing]) ?? -1
    XCTAssertEqual(t2 - t1, 5820, accuracy: 2)   // completed clears the flag; 95 > 90 so only typing may wait
  }
  func testEscStillWorksPastLine() {
    let c = cfg(95)
    var s = Scheduler(config: c)
    let t0 = startAt(&s, from: 0, to: 9000) ?? -1
    XCTAssertEqual(s.finish(.skipped, now: t0), [.endBreak])
    XCTAssertEqual(s.phase, .working)
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
  func testScreenShareKeepsWaitingThenMakeUp() {
    var s = longOnly()
    XCTAssertTrue(startAt(&s, from: 0, to: 7000, reasons: [.screenSharing]) == nil)   // past 90 min, still held
    XCTAssertEqual(s.phase, .paused(.screenSharing))
    XCTAssertEqual((startAt(&s, from: 7001, to: 9000) ?? -1) - 7001, 180, accuracy: 2)
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
    while t < 7200 { s.manualPauseTick(now: t, inputIdle: 10); t += 1 }
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
    for t in stride(from: 0.0, to: 7200, by: 1) { s.manualPauseTick(now: t, inputIdle: 10) }
    XCTAssertEqual(s.phase, .working)
  }
  func testIdleDuringPauseCountsAsLongBreak() {
    var s = Scheduler()
    s.config.longEveryNth = 99
    var t = 0.0
    while t < 3600 {
      _ = s.tick(now: t, reasons: [], inputIdle: 10)
      if case .onBreak = s.phase { _ = s.finish(.completed, now: t) }
      t += 1
    }
    var idle = 0.0
    while t < 7200 { if t > 4000 { idle += 1 }; s.manualPauseTick(now: t, inputIdle: idle); t += 1 }
    XCTAssertTrue(s.sinceLastLongBreak < 90 * 60)
    XCTAssertEqual(s.manualPauseEnded(now: 7200), [])
  }
  func testPauseDoesNotUseDeferBudget() {
    var s = Scheduler()
    for t in stride(from: 0.0, to: 600, by: 1) { s.manualPauseTick(now: t, inputIdle: 10) }
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
    // Skipped past the line (noDeferNextLong set): still binding after a restart.
    _ = s.manualPauseEnded(now: 7200)
    _ = s.finish(.skipped, now: 7210)
    var q = Scheduler()
    q.restore(s.saved(wallClock: 900), wallClock: 930, now: 0)
    XCTAssertTrue(q.longMustNotDefer)
  }
}

let mp = ManualPauseTests()
let dt = DeferralTests()
let st = ScheduleTests()
let pt = PersistenceTests()
let cases: [(String, () -> Void)] = [
 ("shortBreakAt20Min", t.testShortBreakAt20Min), ("everyThirdIsLong", t.testEveryThirdBreakIsLong), ("cycle.skipCounts", t.testSkippedBreakCountsTowardCycle), ("cycle.meetingCountsWhenLongNext", t.testMeetingCountsWhenLongIsNext), ("cycle.migration", t.testLegacyLongEveryMigration), ("cycle.ninetyCap", t.testCycleNinetyCap), ("cycle.countConversion", t.testNthCountConversion), ("menubar.ringStep", t.testRingStep),
 ("pausedTimeDoesNotCount", t.testPausedTimeDoesNotCount), ("meetingOutranksFullscreen", t.testMeetingOutranksFullscreen),
 ("meeting.longEarns", t.testLongMeetingEarnsLongBreak), ("meeting.nearLong", t.testShortMeetingNearLongEarnsLongBreak), ("meeting.resumes", t.testShortMeetingResumes),
 ("waitsForTypingButNotForever", t.testWaitsForTypingButNotForever), ("lidClosedHourDoesNotFireStaleBreak", t.testLidClosedHourDoesNotFireStaleBreak),
 ("idleOnlyOffsetsLongBreak", t.testIdleOnlyOffsetsLongBreak), ("readingWithoutInputStillGetsShortBreak", t.testReadingWithoutInputStillGetsShortBreak), ("snoozeLimit", t.testSnoozeLimit), ("breakEndsOnItsOwn", t.testBreakEndsOnItsOwn),
 ("schedule.crossMidnight", st.testCrossMidnight), ("schedule.timeZoneSwitch", st.testTimeZoneSwitch),
 ("schedule.dstStart", st.testDSTStart), ("schedule.dstEnd", st.testDSTEnd), ("schedule.overrideOff", st.testOverrideOff),
 ("schedule.overrideWindows", st.testOverrideWindows), ("schedule.disabledRule", st.testDisabledRule),
 ("schedule.scheduleDisabled", st.testScheduleDisabled), ("schedule.firstWeekdayIrrelevant", st.testFirstWeekdayIrrelevant),
 ("schedule.nextStart", st.testNextStart),
 ("hours.pauseThenFresh", st.testSchedulerPausesOutsideHoursAndStartsFresh), ("hours.windowEnd", st.testWindowEndPausesMidCount),
 ("hours.meetingOutranks", st.testMeetingOutranksOutsideHours), ("hours.manualBreak", st.testManualBreakOutsideHours),
 ("schedule.nextChange", st.testNextChange),
 ("defer.typing2min", dt.testTypingCappedAt2Min), ("defer.shortBudget", dt.testShortBudgetCapsFocusApp),
 ("defer.focusShortOnly", dt.testFocusModeShortOnlyDoesNotDeferLong), ("defer.concurrentOnce", dt.testSharedBudgetConcurrentCountsOnce),
 ("defer.sequential30", dt.testSharedBudgetSequentialStopsAt30), ("defer.ninetyLine", dt.testNinetyMinuteLineStopsFocusButTypingWaits),
 ("defer.skipPastLine", dt.testSkipPastLineMeansNextLongCannotWait), ("defer.escPastLine", dt.testEscStillWorksPastLine),
 ("defer.videoBudget", dt.testVideoBoundedByBudget), ("defer.videoNinety", dt.testVideoStopsAtNinetyLine),
 ("defer.shareMakeUp", dt.testScreenShareKeepsWaitingThenMakeUp), ("defer.videoMakeUp", dt.testVideoEndMakeUpLongBreak),
 ("defer.priority", dt.testMeetingOutranksScreenShare), ("postpone.shortBudget", dt.testMenuPostponeShortBudget), ("postpone.ninety", dt.testMenuPostponeLongStopsAtNinety), ("schedule.migrationV1", st.testMigrationV1), ("schedule.dayKinds", st.testDayKinds), ("schedule.workdayUnion", st.testWorkdayUnionsWeekdayRules),
 ("pause.expiryForcesLong", mp.testPauseExpiryForcesLongBreak), ("pause.noReminders", mp.testNoRemindersDuringPause),
 ("pause.idleIsLongBreak", mp.testIdleDuringPauseCountsAsLongBreak), ("pause.noDeferBudget", mp.testPauseDoesNotUseDeferBudget),
 ("persist.resume", pt.testResumeAfterRestart), ("persist.gapIsRest", pt.testGapCountsAsRest), ("persist.mustNotDefer", pt.testMustNotDeferSurvivesRestart)]
for (n, f) in cases { let before = failures; f(); print(failures == before ? "ok   \(n)" : "FAIL \(n)") }
print(failures == 0 ? "ALL PASS (\(cases.count))" : "\(failures) failures"); exit(failures == 0 ? 0 : 1)
