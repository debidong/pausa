import Foundation

var failures = 0
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { if a != b { failures += 1; print("FAIL line \(line): \(a) != \(b)") } }
func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double, line: UInt = #line) { if abs(a-b) > accuracy { failures += 1; print("FAIL line \(line): \(a) != \(b)") } }
func XCTAssertEqual(_ a: BreakKind, _ b: BreakKind, line: UInt = #line) { if a != b { failures += 1; print("FAIL line \(line): \(a) != \(b)") } }
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

  func testLongWinsAt50Min() {
    var s = Scheduler()
    var t = 0.0
    var starts: [BreakKind] = []
    while t <= 3200 {
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
    _ = run(&s, from: 601, to: 4000, reasons: [.meeting])
    XCTAssertEqual(s.phase, .paused(.meeting))
    XCTAssertEqual(s.next.remaining, 600, accuracy: 2)
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

let t = SchedulerTests()
let st = ScheduleTests()
let cases: [(String, () -> Void)] = [
 ("shortBreakAt20Min", t.testShortBreakAt20Min), ("longWinsAt50Min", t.testLongWinsAt50Min),
 ("pausedTimeDoesNotCount", t.testPausedTimeDoesNotCount), ("meetingOutranksFullscreen", t.testMeetingOutranksFullscreen),
 ("waitsForTypingButNotForever", t.testWaitsForTypingButNotForever), ("lidClosedHourDoesNotFireStaleBreak", t.testLidClosedHourDoesNotFireStaleBreak),
 ("idleOnlyOffsetsLongBreak", t.testIdleOnlyOffsetsLongBreak), ("readingWithoutInputStillGetsShortBreak", t.testReadingWithoutInputStillGetsShortBreak), ("snoozeLimit", t.testSnoozeLimit), ("breakEndsOnItsOwn", t.testBreakEndsOnItsOwn),
 ("schedule.crossMidnight", st.testCrossMidnight), ("schedule.timeZoneSwitch", st.testTimeZoneSwitch),
 ("schedule.dstStart", st.testDSTStart), ("schedule.dstEnd", st.testDSTEnd), ("schedule.overrideOff", st.testOverrideOff),
 ("schedule.overrideWindows", st.testOverrideWindows), ("schedule.disabledRule", st.testDisabledRule),
 ("schedule.scheduleDisabled", st.testScheduleDisabled), ("schedule.firstWeekdayIrrelevant", st.testFirstWeekdayIrrelevant),
 ("schedule.nextStart", st.testNextStart),
 ("hours.pauseThenFresh", st.testSchedulerPausesOutsideHoursAndStartsFresh), ("hours.windowEnd", st.testWindowEndPausesMidCount),
 ("hours.meetingOutranks", st.testMeetingOutranksOutsideHours), ("hours.manualBreak", st.testManualBreakOutsideHours),
 ("schedule.nextChange", st.testNextChange), ("schedule.migrationV1", st.testMigrationV1)]
for (n, f) in cases { let before = failures; f(); print(failures == before ? "ok   \(n)" : "FAIL \(n)") }
print(failures == 0 ? "ALL PASS (\(cases.count))" : "\(failures) failures"); exit(failures == 0 ? 0 : 1)
