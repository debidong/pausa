import Foundation
import PausaCore

/// Stats on this Mac only: one JSON object per line in ~/Library/Application Support/Pausa/breaks.jsonl
/// (Pausa Dev/breaks.jsonl in the dev build), either a break (`BreakRecord`) or a closed work span (`WorkSpan`). Rows past `keepDays` are dropped at launch.
///
/// The open work span is checkpointed to work-open.json beside it, every few minutes and replaced each
/// time, so the log itself stays append-only. After a crash the next launch appends it as closed at its
/// last checkpoint: at most one checkpoint interval is lost.
final class BreakLog {
    static let keepDays = 30
    static let shared = BreakLog()

    private let url: URL
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    private let openURL: URL

    init(url: URL = BreakLog.defaultURL) {
        self.url = url
        openURL = url.deletingLastPathComponent().appendingPathComponent("work-open.json")
        recoverOpenSpan()
        prune(now: Date())
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appName, isDirectory: true).appendingPathComponent("breaks.jsonl")   // dev build keeps its own stats
    }

    func append(_ r: BreakRecord) { appendLine(r) }
    func append(_ w: WorkSpan) { appendLine(w); try? FileManager.default.removeItem(at: openURL) }

    /// The span still running, as of now. Replaces the previous checkpoint.
    func checkpoint(_ w: WorkSpan) {
        guard !Settings.dryRun, let data = try? encoder.encode(w) else { return }
        try? FileManager.default.createDirectory(at: openURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: openURL, options: .atomic)
    }

    private func recoverOpenSpan() {
        guard let data = try? Data(contentsOf: openURL) else { return }
        if let w = try? decoder.decode(WorkSpan.self, from: data), w.end > w.start { appendLine(w) }
        try? FileManager.default.removeItem(at: openURL)
    }

    private func appendLine<T: Encodable>(_ r: T) {
        guard !Settings.dryRun, var line = try? encoder.encode(r) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try? h.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    /// Unreadable lines (a crash mid-write) are skipped, never fatal.
    /// Both drop rows older than `keepDays` first, so a Pausa left running for weeks still keeps
    /// only 30 days: what the stats page reads is what the bottom card says.
    func all() -> [BreakRecord] { prune(now: Date()); return rows(BreakRecord.self) }
    func work() -> [WorkSpan] { prune(now: Date()); return rows(WorkSpan.self) }

    /// A line is whichever type decodes it (the two have different required keys).
    private func rows<T: Decodable>(_: T.Type) -> [T] {
        lines().compactMap { try? decoder.decode(T.self, from: $0) }
    }

    private func lines() -> [Data] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).map { Data($0) }
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: openURL)
    }

    /// Work rows age by `end`, break rows by `start` (spec §6).
    private struct Dated: Decodable { var start: Date; var end: Date? }

    private func prune(now: Date) {
        let cut = Stats.keepFrom(now: now, days: Self.keepDays, calendar: .current)
        let all = lines()
        let keep = all.filter { (try? decoder.decode(Dated.self, from: $0)).map { ($0.end ?? $0.start) >= cut } ?? false }
        guard keep.count != all.count else { return }
        let body = keep.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        try? body.write(to: url, options: .atomic)
    }

    /// The old per-day short-break counter (`DailyCount`) wrote one UserDefaults key a day and never read it.
    static func removeLegacyKeys() {
        let ud = UserDefaults.standard
        for k in ud.dictionaryRepresentation().keys where k.hasPrefix("shortCount.") { ud.removeObject(forKey: k) }
    }
}
