import Foundation
import PausaCore

/// Stats on this Mac only: one JSON object per line in ~/Library/Application Support/Pausa/breaks.jsonl
/// (Pausa Dev/breaks.jsonl in the dev build), either a break (`BreakRecord`) or a closed work span (`WorkSpan`).
/// Rows past `keepDays` are dropped on read and at launch.
///
/// Each newly written row carries `"row": "break" | "work"` alongside flat fields so old and new builds
/// remain mutually compatible, and `snapshot(now:)` reads, prunes and decodes both row types in one pass.
///
/// The open work span is checkpointed to work-open.json beside it, every few minutes and replaced each
/// time, so the log itself stays append-only. After a crash the next launch appends it as closed at its
/// last checkpoint: at most one checkpoint interval is lost.
final class BreakLog {
    static let keepDays = 30
    static let shared = BreakLog()

    private enum RowTag: String, Codable { case `break`, work }

    private struct TaggedBreak: Encodable {
        let row = RowTag.break
        let start: Date
        let kind: BreakKind
        let planned: Double
        let result: BreakResult
        let appBundleID: String?
        let appName: String?
        let redeemed: Bool?
        init(_ r: BreakRecord) {
            start = r.start; kind = r.kind; planned = r.planned; result = r.result
            appBundleID = r.appBundleID; appName = r.appName
            redeemed = r.redeemed ? true : nil
        }
    }

    private struct TaggedWork: Encodable {
        let row = RowTag.work
        let start: Date
        let end: Date
        let isHold: Bool?
        init(_ w: WorkSpan) {
            start = w.start; end = w.end
            isHold = w.isHold ? true : nil
        }
    }

    /// Decodes both tagged (`"row"`) and legacy untagged JSONL lines in a single pass.
    private struct DecodedRow: Decodable {
        var row: RowTag?
        var start: Date
        var end: Date?
        var kind: BreakKind?
        var planned: Double?
        var result: BreakResult?
        var appBundleID: String?
        var appName: String?
        var redeemed: Bool?
        var isHold: Bool?

        enum Parsed {
            case breakRecord(BreakRecord, agedAt: Date)
            case workSpan(WorkSpan, agedAt: Date)
        }

        var parsed: Parsed? {
            switch row {
            case .break:
                guard let kind, let planned, let result else { return nil }
                return .breakRecord(BreakRecord(start: start, kind: kind, planned: planned, result: result,
                                                appBundleID: appBundleID, appName: appName,
                                                redeemed: redeemed ?? false), agedAt: start)
            case .work:
                guard let end else { return nil }
                return .workSpan(WorkSpan(start: start, end: end, isHold: isHold ?? false), agedAt: end)
            case nil:
                if let kind, let planned, let result {
                    return .breakRecord(BreakRecord(start: start, kind: kind, planned: planned, result: result,
                                                    appBundleID: appBundleID, appName: appName,
                                                    redeemed: redeemed ?? false), agedAt: start)
                }
                if let end {
                    return .workSpan(WorkSpan(start: start, end: end, isHold: isHold ?? false), agedAt: end)
                }
                return nil
            }
        }
    }

    private struct DayAppKey: Hashable {
        let day: Date
        let bundleID: String
    }

    private let url: URL
    private let openURL: URL
    private let appsURL: URL
    private let ignoreDryRun: Bool
    private let calendar: Calendar
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private var appBuffer: [DayAppKey: (name: String, seconds: Double)] = [:]
    private var appDirty = false

    private var canWrite: Bool { ignoreDryRun || !Settings.dryRun }

    init(url: URL = BreakLog.defaultURL, now: Date = Date(), calendar: Calendar = .current, ignoreDryRun: Bool = false) {
        self.url = url
        self.openURL = url.deletingLastPathComponent().appendingPathComponent("work-open.json")
        self.appsURL = url.deletingLastPathComponent().appendingPathComponent("apps.json")
        self.calendar = calendar
        self.ignoreDryRun = ignoreDryRun
        loadAppUsage(now: now)
        recoverOpenSpan()
        _ = snapshot(now: now)
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appName, isDirectory: true).appendingPathComponent("breaks.jsonl")
    }

    func append(_ r: BreakRecord) { appendLine(TaggedBreak(r)) }
    func append(_ w: WorkSpan) { appendLine(TaggedWork(w)); try? FileManager.default.removeItem(at: openURL) }

    /// Marks the most recent unredeemed skipped break within `window` seconds as `redeemed = true`
    /// when a break of matching or higher tier (`completedKind == .long || r.kind == .short`) completes.
    @discardableResult
    func redeemRecentSkip(by completedKind: BreakKind, at now: Date, window: TimeInterval = 300) -> Bool {
        guard canWrite, let data = try? Data(contentsOf: url), !data.isEmpty else { return false }
        let rawLines = data.split(separator: 0x0A)
        let cut = Stats.keepFrom(now: now, days: Self.keepDays, calendar: calendar)
        var parsedRows: [DecodedRow.Parsed] = []
        parsedRows.reserveCapacity(rawLines.count)

        for slice in rawLines {
            guard let decoded = try? decoder.decode(DecodedRow.self, from: Data(slice)),
                  let parsed = decoded.parsed else { continue }
            switch parsed {
            case .breakRecord(_, let agedAt) where agedAt >= cut:
                parsedRows.append(parsed)
            case .workSpan(_, let agedAt) where agedAt >= cut:
                parsedRows.append(parsed)
            default:
                continue
            }
        }

        var targetIndex: Int?
        for i in parsedRows.indices.reversed() {
            if case .breakRecord(let r, _) = parsedRows[i],
               r.result == .skipped, !r.redeemed,
               completedKind == .long || r.kind == .short {
                let elapsed = now.timeIntervalSince(r.start)
                if elapsed >= -5 && elapsed <= window + r.planned {
                    targetIndex = i
                    break
                }
            }
        }
        guard let idx = targetIndex, case .breakRecord(var row, let agedAt) = parsedRows[idx] else {
            return false
        }
        row.redeemed = true
        parsedRows[idx] = .breakRecord(row, agedAt: agedAt)

        var body = Data()
        for item in parsedRows {
            let line: Data? = switch item {
            case .breakRecord(let r, _): try? encoder.encode(TaggedBreak(r))
            case .workSpan(let w, _): try? encoder.encode(TaggedWork(w))
            }
            if let line {
                body.append(line)
                body.append(0x0A)
            }
        }
        try? body.write(to: url, options: .atomic)
        return true
    }

    /// The span still running, as of now. Replaces the previous checkpoint.
    func checkpoint(_ w: WorkSpan) {
        guard canWrite, let data = try? encoder.encode(w) else { return }
        try? FileManager.default.createDirectory(at: openURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: openURL, options: .atomic)
    }

    private func recoverOpenSpan() {
        guard let data = try? Data(contentsOf: openURL) else { return }
        if let w = try? decoder.decode(WorkSpan.self, from: data), w.end > w.start { appendLine(TaggedWork(w)) }
        try? FileManager.default.removeItem(at: openURL)
    }

    private func appendLine<T: Encodable>(_ r: T) {
        guard canWrite, var line = try? encoder.encode(r) else { return }
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

    /// Reads `breaks.jsonl` once, drops corrupt or expired rows (> `keepDays`), rewrites atomically only
    /// if any rows were dropped, and returns both breaks and work spans from that single pass.
    func snapshot(now: Date = Date()) -> (breaks: [BreakRecord], work: [WorkSpan]) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return ([], []) }
        let rawLines = data.split(separator: 0x0A)
        let cut = Stats.keepFrom(now: now, days: Self.keepDays, calendar: calendar)
        var breaks: [BreakRecord] = []
        var work: [WorkSpan] = []
        var kept: [Data.SubSequence] = []
        kept.reserveCapacity(rawLines.count)

        for slice in rawLines {
            guard let decoded = try? decoder.decode(DecodedRow.self, from: Data(slice)),
                  let parsed = decoded.parsed else { continue }
            switch parsed {
            case .breakRecord(let r, let agedAt):
                guard agedAt >= cut else { continue }
                breaks.append(r)
                kept.append(slice)
            case .workSpan(let w, let agedAt):
                guard agedAt >= cut else { continue }
                work.append(w)
                kept.append(slice)
            }
        }

        if canWrite, kept.count != rawLines.count {
            var body = Data()
            for slice in kept {
                body.append(contentsOf: slice)
                body.append(0x0A)
            }
            try? body.write(to: url, options: .atomic)
        }
        return (breaks, work)
    }

    func all(now: Date = Date()) -> [BreakRecord] { snapshot(now: now).breaks }
    func work(now: Date = Date()) -> [WorkSpan] { snapshot(now: now).work }

    private func loadAppUsage(now: Date) {
        guard let data = try? Data(contentsOf: appsURL),
              let rows = try? decoder.decode([AppUsageRecord].self, from: data) else { return }
        let cut = Stats.keepFrom(now: now, days: Self.keepDays, calendar: calendar)
        var pruned = false
        for r in rows where r.seconds > 0 && !r.bundleID.isEmpty {
            let day = calendar.startOfDay(for: r.day)
            guard day >= cut else { pruned = true; continue }
            let key = DayAppKey(day: day, bundleID: r.bundleID)
            let prev = appBuffer[key]
            appBuffer[key] = (r.appName.isEmpty ? (prev?.name ?? r.bundleID) : r.appName, (prev?.seconds ?? 0) + r.seconds)
        }
        if pruned { appDirty = true; flushAppUsage(now: now) }
    }

    func recordAppUsage(bundleID: String, appName: String, seconds: Double, at date: Date) {
        guard seconds > 0, !bundleID.isEmpty else { return }
        let day = calendar.startOfDay(for: date)
        let key = DayAppKey(day: day, bundleID: bundleID)
        let prev = appBuffer[key]
        appBuffer[key] = (appName.isEmpty ? (prev?.name ?? bundleID) : appName, (prev?.seconds ?? 0) + seconds)
        appDirty = true
    }

    func subtractAppUsage(bundleID: String, seconds: Double, on day: Date) {
        guard seconds > 0, !bundleID.isEmpty else { return }
        let key = DayAppKey(day: calendar.startOfDay(for: day), bundleID: bundleID)
        guard let prev = appBuffer[key] else { return }
        let left = prev.seconds - seconds
        if left <= 0.001 {
            appBuffer.removeValue(forKey: key)
        } else {
            appBuffer[key] = (prev.name, left)
        }
        appDirty = true
    }

    func flushAppUsage(now: Date = Date()) {
        guard canWrite, appDirty else { return }
        let cut = Stats.keepFrom(now: now, days: Self.keepDays, calendar: calendar)
        appBuffer = appBuffer.filter { $0.key.day >= cut }
        let records = appBuffer.map {
            AppUsageRecord(day: $0.key.day, bundleID: $0.key.bundleID, appName: $0.value.name, seconds: $0.value.seconds)
        }
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: appsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: appsURL, options: .atomic)
        appDirty = false
    }

    func appUsage(now: Date = Date()) -> [AppUsageRecord] {
        let cut = Stats.keepFrom(now: now, days: Self.keepDays, calendar: calendar)
        return appBuffer.compactMap { entry in
            guard entry.key.day >= cut else { return nil }
            return AppUsageRecord(day: entry.key.day, bundleID: entry.key.bundleID, appName: entry.value.name, seconds: entry.value.seconds)
        }
    }

    func clear() {
        appBuffer.removeAll()
        appDirty = false
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: openURL)
        try? FileManager.default.removeItem(at: appsURL)
    }

    /// The old per-day short-break counter (`DailyCount`) wrote one UserDefaults key a day and never read it.
    static func removeLegacyKeys(defaults ud: UserDefaults = PausaDefaults.store) {
        for k in ud.dictionaryRepresentation().keys where k.hasPrefix(DefaultsKey.legacyShortCountPrefix) {
            ud.removeObject(forKey: k)
        }
    }
}
