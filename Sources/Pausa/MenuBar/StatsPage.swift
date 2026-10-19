import AppKit
import SwiftUI
import PausaCore

/// 统计 (spec v2 §3–4, §8): today's four numbers, the last 7 days, the footnote and the data card.
/// Numbers are computed from the raw log each time it is read; nothing is cached on disk.
@MainActor
final class StatsModel: ObservableObject {
    static let shared = StatsModel()
    static let dayCount = 7

    @Published private(set) var days: [DayStats] = []
    /// Per day (same order as `days`): work seconds before each completed break, one cut in that day's bar.
    /// Any record at all in the log (30 days). Without one the page shows its empty card.
    @Published private(set) var hasData = false
    /// Start of the day picked on the chart; nil = today. Kept as a date so midnight doesn't shift it.
    @Published var selectedDay: Date?

    /// Where the rows come from: the log, plus the work span still running (live app, see `bind`).
    var load: () -> (records: [BreakRecord], work: [WorkSpan], open: WorkSpan?) = { (BreakLog.shared.all(), BreakLog.shared.work(), nil) }
    var clearAll: () -> Void = { BreakLog.shared.clear() }
    var now: () -> Date = Date.init
    var calendar = Calendar.autoupdatingCurrent
    /// Debug renders: data and selection are set by hand; opening the page changes nothing.
    var frozen = false

    private var timer: Timer?
    private var dayObserver: Any?

    func bind(_ app: AppController) {
        load = { [weak app] in (BreakLog.shared.all(), BreakLog.shared.work(), app?.openWorkSpan) }
        clearAll = { [weak app] in app?.clearStats() }
        app.onStatsChanged = { [weak self] in self?.reload() }
    }

    /// The window re-fits 统计 to its content after every reload (set by the settings window).
    var onContentChange: (() -> Void)?

    func reload() {
        let (records, work, open) = load()
        let all = work + (open.map { [$0] } ?? [])   // today's numbers and cuts include the span running now
        days = Stats.days(records, work: all, endingAt: now(), count: Self.dayCount, calendar: calendar)
        // Spec §4 空状态: the full page as soon as the log holds one row, work or break.
        hasData = !records.isEmpty || !work.isEmpty
        if !hasData { selectedDay = nil }
        onContentChange?()
    }

    /// The page came on screen: always today, fresh numbers, then every minute and at midnight.
    func open() {
        guard !frozen else { return }
        selectedDay = nil
        reload()
        timer?.invalidate()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if dayObserver == nil {
            dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    /// Settings window (re)opened: the page may still be in the window, so onAppear won't fire again.
    func showToday() {
        guard !frozen else { return }
        selectedDay = nil
        reload()
    }

    func close() {
        timer?.invalidate(); timer = nil
        if let o = dayObserver { NotificationCenter.default.removeObserver(o); dayObserver = nil }
    }

    var todayIndex: Int { max(0, days.count - 1) }
    var selectedIndex: Int {
        guard let d = selectedDay, let i = days.firstIndex(where: { $0.day == d }) else { return todayIndex }
        return i
    }
    var selected: DayStats { days.indices.contains(selectedIndex) ? days[selectedIndex] : DayStats(day: calendar.startOfDay(for: now())) }
    var isToday: Bool { selectedIndex == todayIndex }

    func select(_ i: Int) {
        guard days.indices.contains(i) else { return }
        selectedDay = i == todayIndex ? nil : days[i].day
    }

    // MARK: 清除数据…

    /// 清除 is destructive; 取消 is the default button and also answers Esc.
    func makeClearAlert() -> (NSAlert, cancel: NSButton) {
        let a = NSAlert()
        a.messageText = L("清除所有统计数据？")
        a.informativeText = L("这台 Mac 上的休息记录将被删除，无法恢复。")
        a.alertStyle = .warning
        let cancel = a.addButton(withTitle: L("取消"))   // first button: default, Return
        let clear = a.addButton(withTitle: L("清除"))
        clear.hasDestructiveAction = true
        clear.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        return (a, cancel)
    }

    func confirmClear(in window: NSWindow?) {
        let (alert, cancel) = makeClearAlert()
        // NSAlert gives Esc only to a button literally titled "Cancel"; 取消 / Annuler etc. get it here.
        let esc = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 53, e.window === alert.window else { return e }
            cancel.performClick(nil)
            return nil
        }
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            if let esc { NSEvent.removeMonitor(esc) }
            guard r == .alertSecondButtonReturn, let self else { return }
            self.clearAll()
            self.selectedDay = nil
            self.reload()
        }
        if let w = window { alert.beginSheetModal(for: w, completionHandler: done) } else { done(alert.runModal()) }
    }
}

// MARK: - text

/// A value as drawn in the number card: big numbers, small units, in the language's own order.
struct ValuePiece: Equatable {
    var pre: String
    var num: String
    var post: String
}

enum StatsText {
    /// 「4 小时 12 分钟」 as (number, unit template) pairs, from PausaCore's DurationParts.
    static func parts(_ seconds: Double) -> [(Int, String)] {
        switch DurationParts(seconds) {
        case .seconds(let n): return [(n, "%d 秒")]
        case .minutes(let n): return [(n, "%d 分钟")]
        case .hours(let h, let m): return [(h, "%d 小时")] + (m > 0 ? [(m, "%d 分钟")] : [])
        }
    }
    /// A number and its unit never break apart.
    static func glue(_ s: String) -> String { s.replacingOccurrences(of: " ", with: "\u{00A0}") }

    static func duration(_ s: Double) -> String {
        parts(s).map { glue(L($0.1, $0.0)) }.joined(separator: " ")
    }

    /// "%d 分钟" -> ("", "18", "分钟"); English "%d" (counts) -> ("", "6", "").
    static func pieces(_ template: String, _ n: Int) -> ValuePiece {
        let parts = L(template).components(separatedBy: "%d")
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespaces) }
        return ValuePiece(pre: trim(parts.first ?? ""), num: "\(n)", post: parts.count > 1 ? trim(parts[1]) : "")
    }
    static func durationPieces(_ s: Double) -> [ValuePiece] { parts(s).map { pieces($0.1, $0.0) } }
    static func countPieces(_ n: Int) -> [ValuePiece] { [pieces("%d 次", n)] }

    /// A sentence template with each "%d" glued to the word after it, then filled in.
    /// `template` is already localized (a `Plural.pick` result).
    static func sentence(_ template: String, _ args: CVarArg...) -> String {
        let t = template.replacingOccurrences(of: "%d ", with: "%d\u{00A0}")
        return String(format: t, locale: AppLanguage.current.locale, arguments: args)
    }

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = AppLanguage.current.locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }
    /// 「10月19日 周一」 / "Mon, Oct 19".
    static func date(_ d: Date) -> String { formatter("MMMdEEE").string(from: d) }
    static func weekday(_ d: Date) -> String { formatter("EEE").string(from: d) }

    /// Hover tip and VoiceOver: 「10月15日 周四：工作 6 小时 20 分钟，完成 13 次休息，休息 23 分钟，跳过 4 次」.
    static func tip(_ s: DayStats, isToday: Bool) -> String {
        sentence(Plural.pick("stats.tip", s.taken), isToday ? L("今天") : date(s.day),
                 duration(s.work), s.taken, duration(s.seconds), s.skipped)
    }
    static func summary(_ days: [DayStats]) -> String {
        sentence(Plural.pick("stats.summary", days.reduce(0) { $0 + $1.taken }),
                 duration(days.reduce(0) { $0 + $1.work }), days.reduce(0) { $0 + $1.taken },
                 duration(days.reduce(0) { $0 + $1.seconds }), days.reduce(0) { $0 + $1.skipped })
    }

    /// Over a bar: 「6.3 小时」 / "6.3 hr" from 1 hour, 「45 分钟」 / "45 min" below; nil without work.
    static func barLabel(_ work: Double) -> String? {
        switch StatsChart.label(work, locale: AppLanguage.current.locale) {
        case .hours(let h)?: return glue(L("%@ 小时", h))
        case .minutes(let m)?: return glue(L("%d 分钟", m))
        case nil: return nil
        }
    }
    /// Under a bar: 「18 次」 / "18 breaks", "1 break".
    static func breaks(_ n: Int) -> String { glue(String(format: Plural.pick("stats.breaks", n), locale: AppLanguage.current.locale, n)) }

    /// Chinese has no spaces, so CoreText may break inside a word (免/打扰). Glue each word's characters
    /// with WORD JOINER (U+2060), using Foundation's own word segmentation plus a few compounds it splits;
    /// other languages unchanged.
    static func keepWords(_ text: String) -> String {
        guard [.zhHans, .zhHant].contains(AppLanguage.current) else { return text }
        var out = "", last = text.startIndex
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { word, r, _, _ in
            guard let word, word.count > 1 else { return }
            out += text[last..<r.lowerBound] + word.map(String.init).joined(separator: "\u{2060}")
            last = r.upperBound
        }
        out += text[last...]
        // Words the system segmenter splits (it gives 免|打扰 and 跳|过).
        for term in ["免打扰", "跳过"] {
            let pattern = term.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\u{2060}?")
            out = out.replacingOccurrences(of: pattern, with: term.map(String.init).joined(separator: "\u{2060}"), options: .regularExpression)
        }
        return out
    }

    static let footnote = "只统计 Pausa 提醒您的休息。开会、共享屏幕、播放视频、全屏、不在提醒时段内或处于免打扰时段时，Pausa 会自动暂停，不会提醒，这段时间也不算跳过。"
}

// MARK: - page

struct StatsPage: View {
    @ObservedObject var model: StatsModel = .shared
    @Environment(\.pausaAccent) private var accent

    var body: some View {
        Form {
            if model.hasData {
                Section {
                    StatsNumbers(day: model.selected).padding(-10).listRowInsets(EdgeInsets())
                } header: { titleRow }
                Section {
                    VStack(spacing: 0) {
                        StatsWeekChart(days: model.days, selected: model.selectedIndex, today: model.todayIndex,
                                       accent: accent, onSelect: model.select)
                            .padding(.top, 14).padding(.horizontal, 16)
                        Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1).padding(.horizontal, 16)
                        Text(StatsText.summary(model.days))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
                    }
                    .padding(-10).listRowInsets(EdgeInsets())
                } header: {
                    HStack {
                        Text(L("过去 7 天")).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                        Spacer()
                        legend
                    }
                    .frame(minHeight: 28)
                } footer: { footnote }
            } else {
                Section {
                    VStack(spacing: 6) {
                        Text(L("还没有休息记录")).font(.system(size: 15, weight: .semibold))
                        Text(L("完成第一次休息后，这里会显示您每天的工作时长和休息情况。"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 48)
                    .frame(maxWidth: .infinity).frame(height: 236)
                    .padding(-10).listRowInsets(EdgeInsets())
                } header: { titleRow } footer: { footnote }
            }
            Section {
                HStack(alignment: .center, spacing: 16) {
                    Text(L("Pausa 将过去 30 天的休息数据存储在本地。")).font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L("清除数据…")) { model.confirmClear(in: NSApp.keyWindow) }
                        .disabled(!model.hasData)
                        .statsProbe("data.button")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(minHeight: 48)
                .statsProbe("data.card")
                .padding(-10).listRowInsets(EdgeInsets())
            }
        }
        .formStyle(.grouped)
        .onAppear { model.open() }
        .onDisappear { model.close() }
    }

    /// 「今天 … 10月19日 周一」, or 「10月15日 周四 … 回到今天」 when another day is picked.
    private var titleRow: some View {
        HStack(alignment: .center) {
            Text(model.isToday ? L("今天") : StatsText.date(model.selected.day))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
            Spacer()
            if model.isToday {
                Text(StatsText.date(model.now())).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Button(L("回到今天")) { model.selectedDay = nil }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(accent)
            }
        }
        .frame(minHeight: 28)
    }

    /// 「柱高：工作时长」 (solid swatch) 「缝隙：一次休息」 (swatch with a cut): the cut can't be guessed.
    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) { GappedBar(cuts: [], radius: 1.5).fill(accent).frame(width: 9, height: 12); Text(L("柱高：工作时长")) }
            HStack(spacing: 5) { GappedBar(cuts: [5.5], radius: 1.5, cut: 1.5).fill(accent).frame(width: 9, height: 12); Text(L("缝隙：一次休息")) }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var footnote: some View {
        // Grouped-form footers are trailing by default; this one reads as a paragraph.
        Text(StatsText.keepWords(L(StatsText.footnote))).font(.system(size: 11)).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 工作时长 / 完成休息 / 休息时长 / 跳过休息: four equal columns, numbers on one baseline, names on another.
struct StatsNumbers: View {
    let day: DayStats
    static let height: CGFloat = 88
    /// The widest value a column must hold: 12 小时 59 分钟.
    static let widest: Double = 12 * 3600 + 59 * 60
    /// 19 pt, or 18 pt for all four when the widest value at 19 pt leaves under 8 pt on a side (spec §8).
    static func numberSize(column: CGFloat, widestAt19: CGFloat) -> CGFloat { (column - widestAt19) / 2 >= 8 ? 19 : 18 }

    var body: some View {
        GeometryReader { g in
            let col = g.size.width / 4
            let size = Self.numberSize(column: col, widestAt19: StatsValue.width(StatsText.durationPieces(Self.widest), size: 19))
            HStack(spacing: 0) {
                cell(0, StatsText.durationPieces(day.work), L("工作时长"), size, col)
                cell(1, StatsText.countPieces(day.taken), L("完成休息"), size, col)
                cell(2, StatsText.durationPieces(day.seconds), L("休息时长"), size, col)
                cell(3, StatsText.countPieces(day.skipped), L("跳过休息"), size, col)
            }
            .overlay(alignment: .topLeading) {
                ForEach(1..<4, id: \.self) { i in
                    Rectangle().fill(Color(nsColor: .separatorColor))
                        .frame(width: 1, height: Self.height - 40)
                        .offset(x: col * CGFloat(i), y: 20)
                }
            }
        }
        .frame(height: Self.height)
    }

    private func cell(_ i: Int, _ v: [ValuePiece], _ name: String, _ size: CGFloat, _ col: CGFloat) -> some View {
        VStack(spacing: 4) {
            StatsValue(pieces: v, size: size).statsProbe("num.value.\(i)")
            Text(name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                .statsProbe("num.label.\(i)")
        }
        .frame(width: col, height: Self.height)
        .statsProbe("num.col.\(i)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(v.map { [$0.pre, $0.num, $0.post].filter { !$0.isEmpty }.joined(separator: " ") }.joined(separator: " "))")
    }
}

/// 「4 小时 12 分钟」: number 19 pt semibold (monospaced digits), unit 11 pt secondary,
/// 2 pt between a number and its unit, 4 pt before the next number. One shared text baseline.
struct StatsValue: View {
    let pieces: [ValuePiece]
    let size: CGFloat
    static let unitGap: CGFloat = 2, pieceGap: CGFloat = 4

    static func numberFont(_ size: CGFloat) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: .semibold) }
    static let unitFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// Drawn width, for the 8 pt rule (same fonts and gaps as `body`).
    static func width(_ pieces: [ValuePiece], size: CGFloat) -> CGFloat {
        func w(_ s: String, _ f: NSFont) -> CGFloat { s.isEmpty ? 0 : ceil((s as NSString).size(withAttributes: [.font: f]).width) }
        return pieces.enumerated().reduce(0) { acc, e in
            let p = e.element
            return acc + (e.offset > 0 ? pieceGap : 0)
                + (p.pre.isEmpty ? 0 : w(p.pre, unitFont) + unitGap) + w(p.num, numberFont(size))
                + (p.post.isEmpty ? 0 : unitGap + w(p.post, unitFont))
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(pieces.indices, id: \.self) { i in
                let p = pieces[i]
                if !p.pre.isEmpty { unit(p.pre).padding(.leading, i > 0 ? Self.pieceGap : 0).padding(.trailing, Self.unitGap) }
                Text(p.num).font(Font(Self.numberFont(size)))
                    .padding(.leading, i > 0 && p.pre.isEmpty ? Self.pieceGap : 0)
                if !p.post.isEmpty { unit(p.post).padding(.leading, Self.unitGap) }
            }
        }
        .lineLimit(1).fixedSize()
    }
    private func unit(_ s: String) -> some View {
        Text(s).font(Font(Self.unitFont)).foregroundStyle(.secondary)
    }
}

// MARK: - chart

/// The 7-day chart, self-contained: fed `[DayStats]`, the cut offsets and the selection; reports taps
/// and arrow keys. Hover tip, VoiceOver label and selection live here, so the drawing can change alone.
/// Spec v2 §8: bar height is work time (PausaCore `StatsChart` owns the scale); every completed break
/// cuts a 1 pt gap at the work time before it. Skips cut nothing. Weekday and breaks taken underneath.
struct StatsWeekChart: View {
    let days: [DayStats]
    let selected: Int
    let today: Int
    let accent: Color
    let onSelect: (Int) -> Void
    @FocusState private var focused: Bool
    @Environment(\.displayScale) private var scale

    /// Room over the tallest bar for its label (and ≥ 8 pt to the card edge): 240 pt bars -> 280 pt area.
    static let labelRoom: CGFloat = 40
    static var plotHeight: CGFloat { CGFloat(StatsChart.plotHeight) + labelRoom }

    var body: some View {
        let longest = days.map(\.work).max() ?? 0
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(days.indices, id: \.self) { i in plotColumn(i, longest) }
            }
            .frame(height: Self.plotHeight)
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            HStack(spacing: 0) {
                ForEach(days.indices, id: \.self) { i in labels(i) }
            }
            .padding(.top, 6).padding(.bottom, 8)
            .accessibilityHidden(true)   // each bar already reads its day
        }
        .focusable()
        .focused($focused)
        .onMoveCommand { d in
            switch d {
            case .left: onSelect(max(0, selected - 1))
            case .right: onSelect(min(days.count - 1, selected + 1))
            default: break
            }
        }
    }

    /// Each completed break's cut (`DayStats.gaps`, placed by `StatsChart.barHeight`): the bottom edge of
    /// a 1 pt cut centred on that height, snapped to whole device pixels. A cut at or above the bar's
    /// top is not drawn (the count line still says every break); cuts on the same row draw as one.
    static func cutRows(_ d: DayStats, longest: Double, scale: CGFloat) -> [CGFloat] {
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let top = snap(CGFloat(StatsChart.barHeight(work: d.work, longest: longest)))
        return d.gaps.map { CGFloat(StatsChart.barHeight(work: $0, longest: longest)) }
            .filter { $0 < top }
            .map { snap($0 - 0.5) }
    }

    private func tap(_ i: Int) { focused = true; onSelect(i) }
    private func hasRecords(_ d: DayStats) -> Bool { d.work > 0 || d.taken + d.skipped > 0 }
    /// Points to whole device pixels, so a 1 pt cut is one clean line, never two half-tone ones.
    private func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

    private func plotColumn(_ i: Int, _ longest: Double) -> some View {
        let d = days[i], on = i == selected
        let h = snap(CGFloat(StatsChart.barHeight(work: d.work, longest: longest)))
        let cuts = Self.cutRows(d, longest: longest, scale: scale)
        return GeometryReader { g in
            let w = snap(g.size.width * CGFloat(StatsChart.barWidthRatio))
            VStack(spacing: 3) {
                Spacer(minLength: 0)
                if let label = StatsText.barLabel(d.work), h > 0 {
                    Text(label)
                        .font(.system(size: 11, weight: on ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(on ? .primary : .secondary)
                        .lineLimit(1).fixedSize()
                        .statsProbe("chart.top.\(i)")
                    GappedBar(cuts: cuts, radius: 4, cut: 1, pixel: 1 / scale).fill(accent.opacity(on ? 1 : 0.38))
                        .frame(width: w, height: h)
                        .statsProbe("chart.bar.\(i)")
                } else {
                    RoundedRectangle(cornerRadius: 1).fill(Color(nsColor: .quaternaryLabelColor))
                        .frame(width: w, height: 2)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .statsProbe("chart.col.\(i)")
        .contentShape(Rectangle())
        .onTapGesture { tap(i) }
        .help(StatsText.tip(d, isToday: i == today))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StatsText.tip(d, isToday: i == today))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect(i) }
    }

    /// 「周四」 / 「13 次」: both bold on the picked day; no count line on a day without records.
    private func labels(_ i: Int) -> some View {
        let d = days[i], on = i == selected
        return VStack(spacing: 0) {
            Text(i == today ? L("今天") : StatsText.weekday(d.day))
                .foregroundStyle(on ? .primary : .secondary)
            Text(hasRecords(d) ? StatsText.breaks(d.taken) : " ")
                .foregroundStyle(.secondary)
                .statsProbe("chart.count.\(i)")
        }
        .font(.system(size: 11, weight: on ? .semibold : .regular).monospacedDigit())
        .lineLimit(1).fixedSize()
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { tap(i) }
        .help(StatsText.tip(d, isToday: i == today))
    }
}

/// A bar with its top corners rounded and horizontal cuts taken OUT of the shape (not painted over),
/// so they show the card through them at any opacity and in dark mode. `cuts` are each cut's bottom
/// edge in points from the bar's bottom; overlapping cuts simply join (each is still drawn).
struct GappedBar: Shape {
    let cuts: [CGFloat]
    let radius: CGFloat
    var cut: CGFloat = 1
    var pixel: CGFloat = 0.5

    func path(in r: CGRect) -> Path {
        // Solid runs between cuts, bottom up, in the shape's own coordinates (y grows downward).
        var runs: [(lo: CGFloat, hi: CGFloat)] = []   // from the bottom
        var y: CGFloat = 0
        for c in cuts.map({ min(max(0, $0), max(0, r.height - cut)) }).sorted() {
            if c > y { runs.append((y, c)) }
            y = max(y, c + cut)
        }
        if r.height > y { runs.append((y, r.height)) }
        var p = Path()
        for run in runs where run.hi - run.lo >= pixel / 2 {
            let rect = CGRect(x: r.minX, y: r.maxY - run.hi, width: r.width, height: run.hi - run.lo)
            if run.hi >= r.height { p.addPath(TopRounded(radius: radius).path(in: rect)) } else { p.addRect(rect) }
        }
        return p
    }
}

/// Rectangle with only the top corners rounded (UnevenRoundedRectangle needs macOS 14).
struct TopRounded: Shape {
    let radius: CGFloat
    func path(in r: CGRect) -> Path {
        let c = min(radius, r.width / 2, r.height)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.addQuadCurve(to: CGPoint(x: r.minX + c, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + c), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - layout probe (debug renders measure the alignment rules from these)

enum StatsProbe {
    static var on = false
    static var frames: [String: CGRect] = [:]
}

extension View {
    @ViewBuilder func statsProbe(_ name: String) -> some View {
        #if DEBUG
        if StatsProbe.on {
            background(GeometryReader { g in
                let _ = (StatsProbe.frames[name] = g.frame(in: .global))
                Color.clear
            })
        } else { self }
        #else
        self
        #endif
    }
}
