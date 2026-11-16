import AppKit
import SwiftUI
import PausaCore

/// 统计: unified single-card eye-care ledger (Style B uniform KPI tiles, bare frameless focus stretches,
/// 7D/30D adaptive trend chart with bar-only selection, real NSWorkspace app icons with monogram fallback,
/// and inline 30-day local retention footer).
@MainActor
final class StatsModel: ObservableObject {
    enum RangeMode: Int, CaseIterable {
        case week = 7
        case month = 30
    }

    static let shared = StatsModel()
    static let dayCount = 7
    static let monthDayCount = 30

    @Published private(set) var monthDays: [DayStats] = []
    @Published private(set) var hasData = false
    @Published var range: RangeMode = .week {
        didSet {
            guard oldValue != range else { return }
            if range == .week, let d = selectedDay, !weekDays.contains(where: { $0.day == d }) {
                selectedDay = nil
            }
            onContentChange?()
        }
    }
    /// Start of the day picked on the chart; nil = today. Kept as a date so midnight doesn't shift it.
    @Published var selectedDay: Date? {
        didSet {
            if oldValue != selectedDay { onContentChange?() }
        }
    }

    var weekDays: [DayStats] { Array(monthDays.suffix(Self.dayCount)) }
    var days: [DayStats] { range == .week ? weekDays : monthDays }

    /// Where the rows come from: the log, the work span still running, and per-day frontmost app usage.
    var load: () -> (records: [BreakRecord], work: [WorkSpan], open: WorkSpan?, apps: [AppUsageRecord]) = {
        let s = BreakLog.shared.snapshot()
        return (s.breaks, s.work, nil, BreakLog.shared.appUsage())
    }
    var clearAll: () -> Void = { BreakLog.shared.clear() }
    var now: () -> Date = Date.init
    var calendar = Calendar.autoupdatingCurrent
    /// Debug renders: data and selection are set by hand; opening the page changes nothing.
    var frozen = false

    private var timer: Timer?
    private var dayObserver: Any?

    func bind(_ app: AppController) {
        load = { [weak app] in
            let now = app?.clock.wallNow() ?? Date()
            let s = BreakLog.shared.snapshot(now: now)
            return (s.breaks, s.work, app?.openWorkSpan, BreakLog.shared.appUsage(now: now))
        }
        clearAll = { [weak app] in app?.clearStats() }
        app.onStatsChanged = { [weak self] in self?.reload() }
    }

    /// The window re-fits 统计 to its content after every reload or height-affecting selection change.
    var onContentChange: (() -> Void)?

    func reload() {
        let (records, work, open, apps) = load()
        let openLive = open.flatMap { $0.end > $0.start ? $0 : nil }
        let all = work + (openLive.map { [$0] } ?? [])
        monthDays = Stats.days(records, work: all, appUsage: apps, endingAt: now(), count: Self.monthDayCount, calendar: calendar)
        hasData = !records.isEmpty || !work.isEmpty || (openLive.map { $0.end.timeIntervalSince($0.start) >= 60 } ?? false)
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
    var selected: DayStats {
        let active = days
        if active.indices.contains(selectedIndex) { return active[selectedIndex] }
        return DayStats(day: calendar.startOfDay(for: now()))
    }
    var isToday: Bool {
        guard let d = selectedDay else { return true }
        return d == calendar.startOfDay(for: now())
    }

    func select(_ i: Int) {
        let active = days
        guard active.indices.contains(i) else { return }
        selectedDay = (i == active.count - 1) ? nil : active[i].day
    }

    func selectToday() {
        selectedDay = nil
    }

    // MARK: 清除数据…

    /// 清除 is destructive; 取消 is the default button and also answers Esc.
    func makeClearAlert() -> (NSAlert, cancel: NSButton) {
        let a = NSAlert()
        a.messageText = L("stats.clear.title")
        a.informativeText = L("stats.clear.message")
        a.alertStyle = .warning
        let cancel = a.addButton(withTitle: L("common.cancel"))   // first button: default, Return
        let clear = a.addButton(withTitle: L("stats.clear.confirm"))
        clear.hasDestructiveAction = true
        clear.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        return (a, cancel)
    }

    /// The alert answered. Take it down first, then clear on the next turn of the run loop: clearing
    /// shrinks the page and the window animates to fit, which must not run while the sheet is attached.
    func finishClear(_ r: NSApplication.ModalResponse, dismiss: () -> Void) {
        dismiss()
        guard r == .alertSecondButtonReturn else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.clearAll()
            self.selectedDay = nil
            self.reload()
        }
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
            self?.finishClear(r) { alert.window.orderOut(nil) }
        }
        if let w = window { alert.beginSheetModal(for: w, completionHandler: done) } else { done(alert.runModal()) }
    }
}

// MARK: - App Icon Resolver (Zero Permissions)

@MainActor
enum AppIconResolver {
    private static var cache: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    /// Reads the application's real macOS bundle icon via public NSWorkspace APIs (zero permissions required).
    /// Returns nil when `bundleID` is empty or the app bundle cannot be found on disk.
    static func icon(for bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        if let hit = cache[bundleID] { return hit }
        if missing.contains(bundleID) { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missing.insert(bundleID)
            return nil
        }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: 18, height: 18)
        cache[bundleID] = img
        return img
    }

    /// Clean monogram fallback when an app bundle is uninstalled or unresolvable.
    static func monogram(for appName: String) -> String {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Ap" }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "." })
        if words.count >= 2, let a = words[0].first, let b = words[1].first, a.isASCII, b.isASCII {
            return String(a).uppercased() + String(b).uppercased()
        }
        let chars = Array(trimmed)
        if chars.count >= 2, chars[0].isASCII, chars[1].isASCII {
            return String(chars[0]).uppercased() + String(chars[1])
        }
        return String(chars[0]).uppercased()
    }
}

// MARK: - Text & Formatting

struct ValuePiece: Equatable {
    var pre: String
    var num: String
    var post: String
}

enum StatsText {
    /// 「4 小时 12 分钟」 as (number, unit template) pairs, from PausaCore's DurationParts (used in status lines & VoiceOver).
    static func parts(_ seconds: Double) -> [(Int, String)] {
        switch DurationParts(seconds) {
        case .seconds(let n): return [(n, "unit.seconds")]
        case .minutes(let n): return [(n, "unit.minutes")]
        case .hours(let h, let m): return [(h, "unit.hours")] + (m > 0 ? [(m, "unit.minutes")] : [])
        }
    }

    static func glue(_ s: String) -> String { s.replacingOccurrences(of: " ", with: "\u{00A0}") }

    static func duration(_ s: Double) -> String {
        parts(s).map { glue(L($0.1, $0.0)) }.joined(separator: " ")
    }

    /// Compact `h` / `m` / `s` pieces for KPI tiles so numbers never overflow in any language.
    static func compactDurationPieces(_ seconds: Double) -> [ValuePiece] {
        switch DurationParts(seconds) {
        case .seconds(let s):
            return [ValuePiece(pre: "", num: "\(s)", post: "s")]
        case .minutes(let m):
            return [ValuePiece(pre: "", num: "\(m)", post: "m")]
        case .hours(let h, let m):
            var out = [ValuePiece(pre: "", num: "\(h)", post: "h")]
            if m > 0 { out.append(ValuePiece(pre: "", num: "\(m)", post: "m")) }
            return out
        }
    }

    /// Longest continuous stretch KPI: keeps minutes up to 99m (`47m`, `58m`) and compact `h`/`m` above that.
    static func stretchPieces(_ seconds: Double) -> [ValuePiece] {
        guard seconds > 0 else { return [ValuePiece(pre: "", num: "0", post: "m")] }
        if seconds < 60 {
            return [ValuePiece(pre: "", num: "\(max(1, Int(seconds.rounded())))", post: "s")]
        }
        let mins = Int((seconds / 60).rounded())
        if mins < 100 {
            return [ValuePiece(pre: "", num: "\(mins)", post: "m")]
        }
        return compactDurationPieces(seconds)
    }

    /// "%d 次" -> ("", "14", "次"); English "%d" -> ("", "14", "").
    static func pieces(_ template: String, _ n: Int) -> ValuePiece {
        let parts = L(template).components(separatedBy: "%d")
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespaces) }
        return ValuePiece(pre: trim(parts.first ?? ""), num: "\(n)", post: parts.count > 1 ? trim(parts[1]) : "")
    }
    static func countPieces(_ n: Int) -> [ValuePiece] { [pieces("unit.count", n)] }

    /// Compact plain duration for app rows (`2h 22m`, `54m`, `0m`).
    static func compactPlainDuration(_ seconds: Double) -> String {
        compactDurationPieces(seconds).map { "\($0.num)\($0.post)" }.joined(separator: " ")
    }

    /// Compact bar top label in 7-day trend (`4.7h`, `46m`, nil when 0).
    static func compactBarLabel(_ work: Double) -> String? {
        guard work > 0 else { return nil }
        if work < 60 { return "\(max(1, Int(work.rounded())))s" }
        if work < 3600 { return "\(Int((work / 60).rounded()))m" }
        return String(format: "%.1fh", locale: AppLanguage.current.locale, work / 3600)
    }

    static func appSkipped(_ n: Int) -> String {
        glue(String(format: Plural.pick("stats.appSkipped", n), locale: AppLanguage.current.locale, n))
    }

    static func sentence(_ template: String, _ args: CVarArg...) -> String {
        let t = template.replacingOccurrences(of: "%d ", with: "%d\u{00A0}")
        return String(format: t, locale: AppLanguage.current.locale, arguments: args)
    }

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = AppLanguage.current.locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    /// 「11月16日 周一」 / "Mon, Nov 16".
    static func date(_ d: Date) -> String { formatter("MMMdEEE").string(from: d) }
    static func weekday(_ d: Date) -> String { formatter("EEE").string(from: d) }
    static func shortMonthDay(_ d: Date) -> String { formatter("Md").string(from: d) }

    /// Hover tip and VoiceOver: 「今天：工作 4 小时 42 分钟，完成 14 次休息，休息 23 分钟，跳过 3 次」.
    static func tip(_ s: DayStats, isToday: Bool) -> String {
        sentence(Plural.pick("stats.tip", s.taken), isToday ? L("stats.today") : date(s.day),
                 duration(s.work), s.taken, duration(s.seconds), s.skipped)
    }

    static func summary(_ days: [DayStats]) -> String {
        sentence(Plural.pick("stats.summary", days.reduce(0) { $0 + $1.taken }),
                 duration(days.reduce(0) { $0 + $1.work }), days.reduce(0) { $0 + $1.taken },
                 duration(days.reduce(0) { $0 + $1.seconds }), days.reduce(0) { $0 + $1.skipped })
    }
}

// MARK: - Surface Palette

private struct StatsPalette {
    let dark: Bool
    var tileFill: Color { dark ? Color.white.opacity(0.048) : Color.black.opacity(0.033) }
    var slotFill: Color { dark ? Color.white.opacity(0.065) : Color.black.opacity(0.044) }
    var divider: Color { dark ? Color.white.opacity(0.085) : Color.black.opacity(0.072) }
    var softLine: Color { dark ? Color.white.opacity(0.052) : Color.black.opacity(0.046) }
    var segActiveFill: Color { dark ? Color.white.opacity(0.13) : Color.white }
}

// MARK: - Page

struct StatsPage: View {
    @ObservedObject var model: StatsModel = .shared
    @Environment(\.pausaAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    private var palette: StatsPalette { StatsPalette(dark: colorScheme == .dark) }

    var body: some View {
        Form {
            Section {
                if model.hasData {
                    VStack(spacing: 0) {
                        headerRow
                            .padding(.horizontal, 18)
                            .padding(.top, 14)
                            .padding(.bottom, 4)

                        StatsKPIGrid(day: model.selected, palette: palette)
                            .padding(.horizontal, 18)
                            .padding(.top, 8)
                            .padding(.bottom, 15)

                        dividerLine

                        StatsStretchesSection(day: model.selected, accent: accent, palette: palette)
                            .padding(.horizontal, 18)
                            .padding(.top, 13)
                            .padding(.bottom, 14)

                        dividerLine

                        StatsTrendSection(
                            days: model.days,
                            range: $model.range,
                            selected: model.selectedIndex,
                            today: model.todayIndex,
                            accent: accent,
                            palette: palette,
                            onSelect: model.select
                        )
                        .padding(.horizontal, 18)
                        .padding(.top, 13)
                        .padding(.bottom, 14)

                        if !model.selected.apps.isEmpty {
                            dividerLine

                            StatsAppsSection(apps: model.selected.apps, accent: accent, palette: palette)
                                .padding(.horizontal, 18)
                                .padding(.top, 13)
                                .padding(.bottom, 15)
                        }
                    }
                    .padding(-10)
                    .listRowInsets(EdgeInsets())
                } else {
                    VStack(spacing: 0) {
                        headerRow
                            .padding(.horizontal, 18)
                            .padding(.top, 14)
                            .padding(.bottom, 6)

                        dividerLine

                        VStack(spacing: 6) {
                            Text(L("stats.empty.title"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(L("stats.empty.message"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 44)
                        .frame(maxWidth: .infinity)
                        .frame(height: 212)
                    }
                    .padding(-10)
                    .listRowInsets(EdgeInsets())
                }
            } footer: {
                footerRow
            }
        }
        .formStyle(.grouped)
        .onAppear { model.open() }
        .onDisappear { model.close() }
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(palette.divider)
            .frame(height: 1)
    }

    private var headerRow: some View {
        let dateText = StatsText.date(model.selected.day)
        let fullTitle = model.isToday ? L("stats.today") + " · " + dateText : dateText
        return HStack(alignment: .center, spacing: 10) {
            Text(fullTitle)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if model.hasData && !model.isToday {
                Button(action: model.selectToday) {
                    Text(L("stats.backToToday"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(accent.opacity(0.11))
                        )
                }
                .buttonStyle(.plain)
                .statsProbe("header.backToToday")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
    }

    private var footerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(L("stats.footer.retention"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                model.confirmClear(in: NSApp.keyWindow)
            } label: {
                Text(L("stats.data.clear"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(model.hasData ? accent : Color(nsColor: .tertiaryLabelColor))
            }
            .buttonStyle(.plain)
            .disabled(!model.hasData)
            .statsProbe("data.button")
        }
        .padding(.top, 3)
        .frame(maxWidth: .infinity)
        .statsProbe("data.card")
    }
}

// MARK: - Style B KPI Tiles (4 Uniform Neutral Tiles)

private struct StatsKPIGrid: View {
    let day: DayStats
    let palette: StatsPalette

    var body: some View {
        HStack(spacing: 8) {
            tile(0, label: L("stats.score"), pieces: [ValuePiece(pre: "", num: "\(day.rhythmScore)", post: "")])
            tile(1, label: L("stats.screenTime"), pieces: StatsText.compactDurationPieces(day.work))
            tile(2, label: L("stats.taken"), pieces: StatsText.countPieces(day.taken))
            tile(3, label: L("stats.longestStretch"), pieces: StatsText.stretchPieces(day.longestStretch))
        }
        .frame(maxWidth: .infinity)
    }

    private func tile(_ index: Int, label: String, pieces: [ValuePiece]) -> some View {
        let spoken = pieces.map { [$0.pre, $0.num, $0.post].filter { !$0.isEmpty }.joined(separator: " ") }.joined(separator: " ")
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .statsProbe("num.label.\(index)")

            StatsKPIValue(pieces: pieces)
                .statsProbe("num.value.\(index)")
        }
        .padding(.horizontal, 11)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.tileFill)
        )
        .statsProbe("num.col.\(index)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(spoken)")
    }
}

private struct StatsKPIValue: View {
    let pieces: [ValuePiece]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(pieces.indices, id: \.self) { i in
                let p = pieces[i]
                if !p.pre.isEmpty {
                    unitText(p.pre)
                        .padding(.leading, i > 0 ? 4 : 0)
                        .padding(.trailing, 2)
                }
                Text(p.num)
                    .font(.system(size: 21.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .padding(.leading, i > 0 && p.pre.isEmpty ? 4 : 0)
                if !p.post.isEmpty {
                    unitText(p.post)
                        .padding(.leading, 2)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.78)
    }

    private func unitText(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11.5, weight: .regular))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Section 1: Bare Frameless Focus Stretches

private struct StatsStretchesSection: View {
    let day: DayStats
    let accent: Color
    let palette: StatsPalette

    private var hasOverwork: Bool {
        day.stretches.contains { $0 >= 40 * 60 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(L("stats.section.stretches"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                if hasOverwork {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(accent)
                            .frame(width: 7, height: 7)
                        Text(L("stats.stretches.over40"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            GeometryReader { geo in
                let totalW = max(0, geo.size.width)
                if day.stretches.isEmpty || totalW <= 0 {
                    Rectangle()
                        .fill(palette.softLine)
                        .frame(width: totalW, height: 1)
                        .frame(width: totalW, height: 18, alignment: .center)
                } else {
                    stretchesRow(availableWidth: totalW)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 18)
            .statsProbe("stretches.row")
        }
    }

    private func stretchesRow(availableWidth: CGFloat) -> some View {
        let n = day.stretches.count
        let weights = day.stretches.map { max(10.0, $0 / 60.0) }
        let sumWeight = weights.reduce(0, +)
        let padWeight = max(0.0, 160.0 - sumWeight)
        let hasPad = padWeight > 0.5
        let itemCount = n + (hasPad ? 1 : 0)

        let gap: CGFloat = n <= 18 ? 4 : max(1.5, min(4, availableWidth * 0.22 / CGFloat(max(1, itemCount - 1))))
        let usable = max(0, availableWidth - gap * CGFloat(max(0, itemCount - 1)))
        let denom = max(1.0, sumWeight + (hasPad ? padWeight : 0))

        return HStack(alignment: .center, spacing: gap) {
            ForEach(day.stretches.indices, id: \.self) { idx in
                let sec = day.stretches[idx]
                let over = sec >= 40 * 60
                let mins = max(1, Int((sec / 60).rounded()))
                let w = max(2, usable * CGFloat(weights[idx] / denom))
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(over ? accent : accent.opacity(0.28))
                    .frame(width: w, height: 18)
                    .overlay {
                        if over && w >= 26 {
                            Text("\(mins)m")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                    }
                    .help(L("stats.stretch.tip", StatsText.duration(sec)))
                    .statsProbe("stretch.pill.\(idx)")
            }

            if hasPad {
                let padW = max(0, usable * CGFloat(padWeight / denom))
                Rectangle()
                    .fill(palette.softLine)
                    .frame(width: padW, height: 1)
            }
        }
        .frame(width: availableWidth, height: 18, alignment: .leading)
    }
}

// MARK: - Section 2: Adaptive 7D / 30D Trend Chart (Bar-Only Selection)

private struct StatsTrendSection: View {
    let days: [DayStats]
    @Binding var range: StatsModel.RangeMode
    let selected: Int
    let today: Int
    let accent: Color
    let palette: StatsPalette
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(L("stats.section.trend"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                rangePicker
            }

            StatsTrendChart(
                days: days,
                range: range,
                selected: selected,
                today: today,
                accent: accent,
                palette: palette,
                onSelect: onSelect
            )
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 2) {
            rangeButton(.week, title: L("stats.range.7d"))
            rangeButton(.month, title: L("stats.range.30d"))
        }
        .padding(1.5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(palette.tileFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(palette.softLine, lineWidth: 0.5)
                )
        )
    }

    private func rangeButton(_ mode: StatsModel.RangeMode, title: String) -> some View {
        let active = (range == mode)
        return Button {
            range = mode
        } label: {
            Text(title)
                .font(.system(size: 11, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? .primary : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 2.5)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .fill(palette.segActiveFill)
                            .shadow(color: .black.opacity(0.08), radius: 1.5, x: 0, y: 0.5)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

struct StatsTrendChart: View {
    let days: [DayStats]
    let range: StatsModel.RangeMode
    let selected: Int
    let today: Int
    let accent: Color
    fileprivate let palette: StatsPalette
    let onSelect: (Int) -> Void

    @FocusState private var focused: Bool
    @State private var hoveredIndex: Int?
    @Environment(\.displayScale) private var scale

    static let topLabelBand: CGFloat = 18
    static let barPlotHeight: CGFloat = 100
    static let bottomLabelBand: CGFloat = 22
    static let rightAxisGutter: CGFloat = 28
    static var totalHeight: CGFloat { topLabelBand + barPlotHeight + bottomLabelBand }

    var body: some View {
        let longest = days.map(\.work).max() ?? 0
        let ceilH = StatsTrendScale.ceilingHours(longest: longest)
        let ceilSec = Double(ceilH) * 3600.0
        let midText = ceilH % 2 == 0 ? "\(ceilH / 2)h" : String(format: "%.1fh", Double(ceilH) / 2.0)

        ZStack(alignment: .topLeading) {
            referenceLines(topText: "\(ceilH)h", midText: midText)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(days.indices, id: \.self) { i in
                        barColumn(i, ceilSec: ceilSec)
                    }
                }
                .frame(height: Self.topLabelBand + Self.barPlotHeight)
                .padding(.trailing, Self.rightAxisGutter)

                bottomAxisLabels
                    .frame(height: Self.bottomLabelBand)
                    .padding(.trailing, Self.rightAxisGutter)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.totalHeight)
        .focusable()
        .focused($focused)
        .noFocusRing()
        .accessibilityLabel(StatsText.summary(days))
        .onMoveCommand { dir in
            switch dir {
            case .left: onSelect(max(0, selected - 1))
            case .right: onSelect(min(max(0, days.count - 1), selected + 1))
            default: break
            }
        }
    }

    private func snap(_ v: CGFloat) -> CGFloat {
        let s = max(1, scale)
        return (v * s).rounded() / s
    }

    private func referenceLines(topText: String, midText: String) -> some View {
        ZStack(alignment: .topLeading) {
            gridLine(y: Self.topLabelBand, label: topText, dashed: true)
            gridLine(y: Self.topLabelBand + Self.barPlotHeight / 2, label: midText, dashed: true)
            gridLine(y: Self.topLabelBand + Self.barPlotHeight, label: "0h", dashed: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func gridLine(y: CGFloat, label: String, dashed: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0.5))
                p.addLine(to: CGPoint(x: 2000, y: 0.5))
            }
            .stroke(
                dashed ? palette.softLine : palette.divider,
                style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 3] : [])
            )
            .frame(height: 1)
            .clipped()

            Text(label)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.bottom, 3)
        }
        .frame(maxWidth: .infinity)
        .offset(y: y - 14)
        .frame(height: 15, alignment: .bottom)
    }

    private func barColumn(_ i: Int, ceilSec: Double) -> some View {
        let d = days[i]
        let on = (i == selected)
        let hovered = (hoveredIndex == i)
        let rawH = d.work <= 0 ? 0 : max(4, Self.barPlotHeight * CGFloat(min(1.0, d.work / ceilSec)))
        let h = d.work <= 0 ? 0 : snap(rawH)

        return GeometryReader { g in
            let barW: CGFloat = range == .week
                ? snap(min(24, g.size.width * 0.56))
                : snap(min(7.5, max(3.5, g.size.width * 0.58)))
            let radius: CGFloat = range == .week ? 4.5 : 2.0

            VStack(spacing: 3) {
                Spacer(minLength: 0)

                if range == .week, let topLabel = StatsText.compactBarLabel(d.work), h > 0 {
                    Text(topLabel)
                        .font(.system(size: 10, weight: on ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(on ? .primary : .tertiary)
                        .lineLimit(1)
                        .fixedSize()
                        .statsProbe("chart.top.\(i)")
                }

                if h > 0 {
                    TopRounded(radius: radius)
                        .fill(on ? accent : (hovered ? accent.opacity(0.44) : accent.opacity(0.28)))
                        .frame(width: barW, height: h)
                        .statsProbe("chart.bar.\(i)")
                } else {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(on ? accent : palette.divider)
                        .frame(width: barW, height: 2)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .statsProbe("chart.col.\(i)")
        .contentShape(Rectangle())
        .onHover { isIn in
            if isIn { hoveredIndex = i } else if hoveredIndex == i { hoveredIndex = nil }
        }
        .onTapGesture {
            focused = true
            onSelect(i)
        }
        .help(StatsText.tip(d, isToday: i == today))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StatsText.tip(d, isToday: i == today))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect(i) }
    }

    @ViewBuilder
    private var bottomAxisLabels: some View {
        if range == .week {
            HStack(spacing: 0) {
                ForEach(days.indices, id: \.self) { i in
                    let d = days[i]
                    let on = (i == selected)
                    Text(i == today ? L("stats.today") : StatsText.weekday(d.day))
                        .font(.system(size: 11, weight: on ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(on ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 1)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            focused = true
                            onSelect(i)
                        }
                        .help(StatsText.tip(d, isToday: i == today))
                        .statsProbe("chart.day.\(i)")
                }
            }
            .accessibilityHidden(true)
        } else {
            GeometryReader { g in
                let count = max(1, days.count)
                let colW = g.size.width / CGFloat(count)
                let anchors = [0, 9, 19, count - 1].filter { days.indices.contains($0) }
                ZStack(alignment: .bottomLeading) {
                    ForEach(anchors, id: \.self) { idx in
                        let on = (idx == selected)
                        let text = idx == today ? L("stats.today") : StatsText.shortMonthDay(days[idx].day)
                        let center = (CGFloat(idx) + 0.5) * colW
                        Text(text)
                            .font(.system(size: 10, weight: on ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(on ? .primary : .secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .position(
                                x: max(12, center),
                                y: g.size.height - 6
                            )
                    }
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// Rectangle with only the top corners rounded (compatible with macOS 13+).
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

// MARK: - Section 3: App Screen Time (Real NSWorkspace Icon + Un-clipped Skip Badge)

private struct StatsAppsSection: View {
    let apps: [AppUsageSummary]
    let accent: Color
    let palette: StatsPalette

    var body: some View {
        let maxSec = max(30 * 60.0, apps.map(\.seconds).max() ?? 0)
        VStack(alignment: .leading, spacing: 10) {
            Text(L("stats.section.apps"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            VStack(spacing: 9) {
                ForEach(Array(apps.enumerated()), id: \.element.bundleID) { idx, app in
                    StatsAppRow(index: idx, app: app, maxSeconds: maxSec, accent: accent, palette: palette)
                }
            }
        }
    }
}

private struct StatsAppRow: View {
    let index: Int
    let app: AppUsageSummary
    let maxSeconds: Double
    let accent: Color
    let palette: StatsPalette

    static let rowHeight: CGFloat = 22
    static let durationWidth: CGFloat = 56
    static let columnGap: CGFloat = 12

    var body: some View {
        GeometryReader { g in
            let idWidth = min(220, max(188, floor(g.size.width * 0.46)))
            let trackWidth = max(40, g.size.width - idWidth - Self.durationWidth - Self.columnGap * 2)
            let fillRatio = maxSeconds > 0 ? min(1.0, max(0, app.seconds / maxSeconds)) : 0
            let fillWidth = app.seconds > 0 ? max(5.5, round(trackWidth * CGFloat(fillRatio))) : 0

            HStack(alignment: .center, spacing: Self.columnGap) {
                // Leading column: [18x18 real icon or monogram] + [truncatable name] + [guaranteed un-clipped skip badge]
                HStack(alignment: .center, spacing: 7) {
                    StatsAppIconView(bundleID: app.bundleID, appName: app.name, accent: accent)

                    Text(app.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(0)

                    if app.skipped > 0 {
                        Text(StatsText.appSkipped(app.skipped))
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(accent)
                            .lineLimit(1)
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 2.5)
                            .background(
                                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                    .fill(accent.opacity(0.11))
                            )
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(2)
                            .statsProbe("app.badge.\(index)")
                    }
                }
                .frame(width: idWidth, alignment: .leading)
                .help(app.name)

                // Middle column: capsule bar starting on a strict vertical plumb line
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(palette.slotFill)
                        .frame(width: trackWidth, height: 5.5)
                    if fillWidth > 0 {
                        Capsule()
                            .fill(index == 0 ? accent : accent.opacity(0.56))
                            .frame(width: min(trackWidth, fillWidth), height: 5.5)
                    }
                }
                .frame(width: trackWidth, height: 5.5)
                .statsProbe("app.track.\(index)")

                // Trailing column: right-aligned tabular duration
                Text(StatsText.compactPlainDuration(app.seconds))
                    .font(.system(size: 11.5, weight: index == 0 ? .semibold : .medium).monospacedDigit())
                    .foregroundStyle(index == 0 ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(width: Self.durationWidth, alignment: .trailing)
            }
            .frame(width: g.size.width, height: Self.rowHeight)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.rowHeight)
        .statsProbe("app.row.\(index)")
        .accessibilityElement(children: .combine)
    }
}

private struct StatsAppIconView: View {
    let bundleID: String
    let appName: String
    let accent: Color

    var body: some View {
        if let nsImage = AppIconResolver.icon(for: bundleID) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        } else {
            Text(AppIconResolver.monogram(for: appName))
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(accent.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .strokeBorder(accent.opacity(0.22), lineWidth: 0.5)
                        )
                )
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Layout Probe (Debug Renders Measure Alignment Rules From These)

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

extension View {
    /// Hide the system focus ring (macOS 14+; macOS 13 keeps it).
    @ViewBuilder func noFocusRing() -> some View {
        if #available(macOS 14, *) { focusEffectDisabled() } else { self }
    }
}
