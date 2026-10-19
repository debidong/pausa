import Foundation
import PausaCore

/// Break records on this Mac only: one JSON object per line in
/// ~/Library/Application Support/Pausa/breaks.jsonl. Rows past `keepDays` are dropped at launch.
final class BreakLog {
    static let keepDays = 30
    static let shared = BreakLog()

    private let url: URL
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    init(url: URL = BreakLog.defaultURL) {
        self.url = url
        prune(now: Date())
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pausa", isDirectory: true).appendingPathComponent("breaks.jsonl")
    }

    func append(_ r: BreakRecord) {
        guard var line = try? encoder.encode(r) else { return }
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
    func all() -> [BreakRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(BreakRecord.self, from: Data($0)) }
    }

    func clear() { try? FileManager.default.removeItem(at: url) }

    private func prune(now: Date) {
        guard let cut = Calendar.current.date(byAdding: .day, value: -Self.keepDays, to: now) else { return }
        let rows = all(), keep = rows.filter { $0.start >= cut }
        guard keep.count != rows.count else { return }
        let body = keep.compactMap { try? encoder.encode($0) }.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        try? body.write(to: url, options: .atomic)
    }

    /// The old per-day short-break counter (`DailyCount`) wrote one UserDefaults key a day and never read it.
    static func removeLegacyKeys() {
        let ud = UserDefaults.standard
        for k in ud.dictionaryRepresentation().keys where k.hasPrefix("shortCount.") { ud.removeObject(forKey: k) }
    }
}
