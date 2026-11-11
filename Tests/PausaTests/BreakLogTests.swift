import XCTest
@testable import Pausa
@testable import PausaCore

final class BreakLogTests: XCTestCase {
    private var tempDir: URL!
    private var cal: Calendar!

    override func setUpWithError() throws {
        try super.setUpWithError()
        Settings.dryRun = false
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pausa-breaklog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        cal = c
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: iso)!
    }

    func testTaggedAndLegacyRowsDecodeInSingleSnapshotAndPruneExpired() throws {
        let logURL = tempDir.appendingPathComponent("breaks.jsonl")
        let now = date("2026-10-20T12:00:00Z")

        // Seed legacy untagged rows, an expired row (>30 days old), and a truncated crash line.
        let seedLines = [
            #"{"start":"2026-09-01T10:00:00Z","kind":"short","planned":20,"result":"completed"}"#,
            #"{"start":"2026-10-19T09:00:00Z","kind":"short","planned":20,"result":"completed"}"#,
            #"{"start":"2026-10-19T09:00:20Z","end":"2026-10-19T10:00:00Z"}"#,
            #"{"start":"2026-10-19T10:05:00Z","broken_json"#,
        ].joined(separator: "\n") + "\n"
        try Data(seedLines.utf8).write(to: logURL)

        let log = BreakLog(url: logURL, now: now, calendar: cal, ignoreDryRun: true)
        log.append(BreakRecord(start: date("2026-10-20T10:00:00Z"), kind: .long, planned: 300, result: .completed))
        log.append(WorkSpan(start: date("2026-10-20T10:05:00Z"), end: date("2026-10-20T11:30:00Z")))

        let snap = log.snapshot(now: now)
        XCTAssertEqual(snap.breaks.count, 2)
        XCTAssertEqual(snap.breaks.map(\.kind), [.short, .long])
        XCTAssertEqual(snap.work.count, 2)

        // Verify expired and corrupt lines were pruned and newly appended rows carry explicit `"row"` tags.
        let raw = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("2026-09-01"))
        XCTAssertFalse(raw.contains("broken_json"))
        XCTAssertTrue(raw.contains(#""row":"break""#))
        XCTAssertTrue(raw.contains(#""row":"work""#))
    }

    func testCrashCheckpointRecoveryClosesOpenWorkSpan() throws {
        let logURL = tempDir.appendingPathComponent("breaks.jsonl")
        let openURL = tempDir.appendingPathComponent("work-open.json")
        let now = date("2026-10-20T12:00:00Z")

        do {
            let crashedSession = BreakLog(url: logURL, now: now, calendar: cal, ignoreDryRun: true)
            crashedSession.checkpoint(WorkSpan(start: date("2026-10-20T09:00:00Z"), end: date("2026-10-20T09:45:00Z")))
            XCTAssertTrue(FileManager.default.fileExists(atPath: openURL.path))
        }

        let relaunched = BreakLog(url: logURL, now: now, calendar: cal, ignoreDryRun: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: openURL.path))
        let snap = relaunched.snapshot(now: now)
        XCTAssertEqual(snap.work, [WorkSpan(start: date("2026-10-20T09:00:00Z"), end: date("2026-10-20T09:45:00Z"))])
    }
}
