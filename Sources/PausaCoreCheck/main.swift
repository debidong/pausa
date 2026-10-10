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

let t = SchedulerTests()
let cases: [(String, () -> Void)] = [
 ("shortBreakAt20Min", t.testShortBreakAt20Min), ("longWinsAt50Min", t.testLongWinsAt50Min),
 ("pausedTimeDoesNotCount", t.testPausedTimeDoesNotCount), ("meetingOutranksFullscreen", t.testMeetingOutranksFullscreen),
 ("waitsForTypingButNotForever", t.testWaitsForTypingButNotForever), ("lidClosedHourDoesNotFireStaleBreak", t.testLidClosedHourDoesNotFireStaleBreak),
 ("idleOnlyOffsetsLongBreak", t.testIdleOnlyOffsetsLongBreak), ("snoozeLimit", t.testSnoozeLimit), ("breakEndsOnItsOwn", t.testBreakEndsOnItsOwn)]
for (n, f) in cases { let before = failures; f(); print(failures == before ? "ok   \(n)" : "FAIL \(n)") }
print(failures == 0 ? "ALL PASS (\(cases.count))" : "\(failures) failures"); exit(failures == 0 ? 0 : 1)
