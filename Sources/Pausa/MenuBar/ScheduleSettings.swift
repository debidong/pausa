import SwiftUI
import PausaCore

/// Formatting shared by the Pausa 时段 page and the menu.
enum ScheduleFormat {
    static var cal: Calendar { var c = Calendar.current; c.locale = AppLanguage.current.locale; return c }
    static func time(_ t: ClockTime) -> String { AppController.colonPair(t.minutes) }
    /// The one time-range formatter: spaced en dash, "9:00 – 12:00" (U+2013). 0:00 – 0:00 = all day.
    static func range(_ a: ClockTime, _ b: ClockTime) -> String {
        a.minutes == 0 && b.minutes == 0 ? L("schedule.allDay") : "\(time(a)) \u{2013} \(time(b))"
    }
    /// Weekdays in display order (respects firstWeekday), 1...7 = Sun...Sat.
    static var orderedWeekdays: [Int] { let f = cal.firstWeekday; return (0..<7).map { (f - 1 + $0) % 7 + 1 } }
    static func summary(_ days: Set<Int>) -> String {
        let sym = cal.shortStandaloneWeekdaySymbols
        if days.isEmpty { return L("schedule.repeat.never") }
        if days.count == 7 { return L("schedule.repeat.everyDay") }
        if days == [2, 3, 4, 5, 6] { return L("schedule.repeat.weekdays") }
        if days == [1, 7] { return L("schedule.repeat.weekends") }
        return orderedWeekdays.filter(days.contains).map { sym[$0 - 1] }.joined(separator: " ")
    }
    /// 特定日期 row date: zh "10 月 11 日" (spaced, Ruan Yifeng), others the locale's short month-day.
    static func monthDay(_ k: DateKey) -> String {
        if AppLanguage.current.locale.identifier.hasPrefix("zh") { return "\(k.m) 月 \(k.d) 日" }
        let f = DateFormatter(); f.locale = AppLanguage.current.locale
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: cal.date(from: DateComponents(year: k.y, month: k.m, day: k.d, hour: 12)) ?? Date())
    }
    static func day(_ k: DateKey) -> String {
        let f = DateFormatter(); f.locale = AppLanguage.current.locale
        f.setLocalizedDateFormatFromTemplate("yMMMd EEE")
        return f.string(from: cal.date(from: DateComponents(year: k.y, month: k.m, day: k.d, hour: 12)) ?? Date())
    }
}

enum HoursSide: CaseIterable { case include, exclude
    var path: WritableKeyPath<PausaSchedule, HoursSet> { self == .include ? \.include : \.exclude }
}

/// Draft state for the one sheet (ObservableObject: no @State needed).
final class ScheduleEditor: ObservableObject {
    static let shared = ScheduleEditor()
    struct Target: Identifiable { let side: HoursSide; let rule: UUID?; let isDate: Bool; let dateKey: DateKey?
        var id: String { "\(side)-\(rule?.uuidString ?? "")-\(isDate)-\(dateKey.map { "\($0.y)\($0.m)\($0.d)" } ?? "")" } }
    @Published var target: Target?
    @Published var start = Date()
    @Published var end = Date()
    @Published var days: Set<Int> = [2, 3, 4, 5, 6]
    @Published var day = Date()
    @Published var kind: DayKind = .off

    static func date(_ t: ClockTime) -> Date {
        Calendar.current.date(bySettingHour: t.minutes / 60, minute: t.minutes % 60, second: 0, of: Date()) ?? Date()
    }
    static func clock(_ d: Date) -> ClockTime {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d); return ClockTime(c.hour ?? 0, c.minute ?? 0)
    }

    func editRule(_ side: HoursSide, _ r: PausaWindow?) {
        let r = r ?? (side == .include ? PausaWindow(start: ClockTime(9), end: ClockTime(18), weekdays: [2, 3, 4, 5, 6])
                                       : PausaWindow(start: ClockTime(12), end: ClockTime(13, 30), weekdays: [2, 3, 4, 5, 6]))
        start = Self.date(r.start); end = Self.date(r.end); days = r.weekdays
        target = Target(side: side, rule: r.id, isDate: false, dateKey: nil)
    }
    func editDate(_ k: DateKey?, _ kind: DayKind?) {
        day = k.flatMap { Calendar.current.date(from: DateComponents(year: $0.y, month: $0.m, day: $0.d, hour: 12)) } ?? Date()
        self.kind = kind ?? .off   // Steve: a new date defaults to 休息
        target = Target(side: .exclude, rule: nil, isDate: true, dateKey: k)
    }
}

/// "Pausa 时段" on the 休息 page: 提醒时段, 免打扰时段 and 特定日期 groups (Steve).
/// Model: include/exclude weekly rules (exclude wins) plus per-date 上班/休息 kinds.
struct ScheduleSection: View {
    @ObservedObject var settings: Settings
    @ObservedObject var editor = ScheduleEditor.shared
    private var ruleTarget: Binding<ScheduleEditor.Target?> {
        Binding(get: { editor.target?.isDate == false ? editor.target : nil }, set: { editor.target = $0 })
    }
    private var dateTarget: Binding<ScheduleEditor.Target?> {
        Binding(get: { editor.target?.isDate == true ? editor.target : nil }, set: { editor.target = $0 })
    }
    private var dates: [(DateKey, DayKind)] {
        settings.schedule.days.map { ($0.key, $0.value) }.sorted { ($0.0.y, $0.0.m, $0.0.d) < ($1.0.y, $1.0.m, $1.0.d) }
    }

    var body: some View {
        // Steve: 提醒时段 and 免打扰时段 are separate groups; the group decides a new range's type.
        // 特定日期 is a third group: one row per date, 上班 or 休息.
        Group {
            Section {
                Toggle(L("schedule.activeOnly"), isOn: $settings.schedule.enabled.animation())
                if settings.schedule.enabled {
                    ForEach(settings.schedule.include.rules) { r in RuleRow(settings: settings, editor: editor, side: .include, r: r) }
                    LabeledContent(L("schedule.active.add")) { Button(L("common.add")) { editor.editRule(.include, nil) } }
                }
            } header: {
                Text(L("schedule.active"))
            }
            if settings.schedule.enabled {
                Section {
                    ForEach(settings.schedule.exclude.rules) { r in RuleRow(settings: settings, editor: editor, side: .exclude, r: r) }
                    LabeledContent(L("schedule.quiet.add")) { Button(L("common.add")) { editor.editRule(.exclude, nil) } }
                } header: {
                    Text(L("schedule.quiet"))
                } footer: {
                    FormFooter(L("schedule.quiet.footer"))
                }
                Section {
                    ForEach(dates, id: \.0) { k, kind in
                        LabeledContent("\(ScheduleFormat.monthDay(k)) · \(kind == .work ? L("schedule.day.work") : L("schedule.day.off"))") {
                            Button(L("common.edit")) { editor.editDate(k, kind) }
                        }
                        .monospacedDigit()
                    }
                    LabeledContent(L("schedule.dates.add")) { Button(L("common.add")) { editor.editDate(nil, nil) } }
                } header: {
                    Text(L("schedule.dates"))
                } footer: {
                    FormFooter(L("schedule.dates.footer"))
                }
            }
        }
        .sheet(item: ruleTarget) { t in RuleSheet(settings: settings, editor: editor, t: t) }
        .sheet(item: dateTarget) { t in DateSheet(settings: settings, editor: editor, t: t) }
    }
}

/// One weekly range: display-only text on the left, one 编辑 button on the right (Steve).
private struct RuleRow: View {
    @ObservedObject var settings: Settings
    @ObservedObject var editor: ScheduleEditor
    let side: HoursSide, r: PausaWindow
    var body: some View {
        LabeledContent("\(ScheduleFormat.range(r.start, r.end)) \(ScheduleFormat.summary(r.weekdays))") {
            Button(L("common.edit")) { editor.editRule(side, r) }
        }
        .monospacedDigit()
    }
}

private struct SheetButtons: View {
    var onDelete: (() -> Void)?
    var deleteTitle = L("common.delete")
    let onCancel: () -> Void, onDone: () -> Void
    var doneDisabled = false
    var body: some View {
        HStack {
            if let d = onDelete { Button(deleteTitle, role: .destructive, action: d).foregroundStyle(.red) }
            Spacer()
            Button(L("common.cancel"), action: onCancel).keyboardShortcut(.cancelAction)
            Button(L("common.done"), action: onDone).keyboardShortcut(.defaultAction).disabled(doneDisabled)
        }
        .padding([.horizontal, .bottom], 20)
    }
}

private struct RuleSheet: View {
    @ObservedObject var settings: Settings
    @ObservedObject var editor: ScheduleEditor
    let t: ScheduleEditor.Target
    private var existing: Int? { t.rule.flatMap { id in settings.schedule[keyPath: t.side.path].rules.firstIndex { $0.id == id } } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(t.side == .include ? L("schedule.active") : L("schedule.quiet")) {
                    DatePicker(L("schedule.start"), selection: $editor.start, displayedComponents: .hourAndMinute)
                    DatePicker(L("schedule.end"), selection: $editor.end, displayedComponents: .hourAndMinute)
                    LabeledContent(L("schedule.repeat")) {
                        HStack(spacing: 2) {
                            ForEach(ScheduleFormat.orderedWeekdays, id: \.self) { wd in
                                Toggle(ScheduleFormat.cal.veryShortStandaloneWeekdaySymbols[wd - 1], isOn: Binding(
                                    get: { editor.days.contains(wd) },
                                    set: { on in if on { editor.days.insert(wd) } else { editor.days.remove(wd) } }))
                                    .toggleStyle(.button)
                            }
                        }
                    }
                }
                if ScheduleEditor.clock(editor.end) <= ScheduleEditor.clock(editor.start) {
                    Text(L("schedule.crossesMidnight")).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped).scrollDisabled(true)
            SheetButtons(onDelete: existing.map { i in { settings.schedule[keyPath: t.side.path].rules.remove(at: i); editor.target = nil } },
                         deleteTitle: L("schedule.hours.delete"),
                         onCancel: { editor.target = nil }, onDone: save, doneDisabled: editor.days.isEmpty)
        }
        .frame(width: 400)
        .environment(\.locale, AppLanguage.current.locale)
    }

    private func save() {
        let s = ScheduleEditor.clock(editor.start), e = ScheduleEditor.clock(editor.end)
        if let i = existing {
            settings.schedule[keyPath: t.side.path].rules[i].start = s
            settings.schedule[keyPath: t.side.path].rules[i].end = e
            settings.schedule[keyPath: t.side.path].rules[i].weekdays = editor.days
        } else {
            settings.schedule[keyPath: t.side.path].rules.append(PausaWindow(start: s, end: e, weekdays: editor.days))
        }
        editor.target = nil
    }
}

struct DateSheet: View {
    @ObservedObject var settings: Settings
    @ObservedObject var editor: ScheduleEditor
    let t: ScheduleEditor.Target
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(L("schedule.dates")) {
                    DatePicker(L("schedule.date"), selection: $editor.day, displayedComponents: .date)
                    Picker(L("schedule.dayIs"), selection: $editor.kind) {
                        Text(L("schedule.day.work")).tag(DayKind.work)
                        Text(L("schedule.day.off")).tag(DayKind.off)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .formStyle(.grouped).scrollDisabled(true)
            SheetButtons(onDelete: t.dateKey.map { k in { settings.schedule.days[k] = nil; editor.target = nil } },
                         deleteTitle: L("schedule.dates.delete"),
                         onCancel: { editor.target = nil }, onDone: save)
        }
        .frame(width: 400)
        .environment(\.locale, AppLanguage.current.locale)
    }
    private func save() {
        let k = DateKey(editor.day, cal: Calendar.current)
        if let old = t.dateKey, old != k { settings.schedule.days[old] = nil }
        settings.schedule.days[k] = editor.kind
        editor.target = nil
    }
}

/// Sub-rows (rules under 仅在指定时段提醒, apps under 使用指定应用时) sit one step in.
