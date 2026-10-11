import SwiftUI
import PausaCore

/// Formatting shared by the Pausa 时段 page and the menu.
enum ScheduleFormat {
    static var cal: Calendar { var c = Calendar.current; c.locale = AppLanguage.current.locale; return c }
    static func time(_ t: ClockTime) -> String { String(format: "%d:%02d", t.minutes / 60, t.minutes % 60) }
    /// The one time-range formatter: spaced en dash, "9:00 – 12:00" (U+2013). 0:00 – 0:00 = all day.
    static func range(_ a: ClockTime, _ b: ClockTime) -> String {
        a.minutes == 0 && b.minutes == 0 ? L("全天") : "\(time(a)) \u{2013} \(time(b))"
    }
    /// Weekdays in display order (respects firstWeekday), 1...7 = Sun...Sat.
    static var orderedWeekdays: [Int] { let f = cal.firstWeekday; return (0..<7).map { (f - 1 + $0) % 7 + 1 } }
    static func summary(_ days: Set<Int>) -> String {
        let sym = cal.shortStandaloneWeekdaySymbols
        if days.isEmpty { return L("从不") }
        if days.count == 7 { return L("每天") }
        if days == [2, 3, 4, 5, 6] { return L("工作日") }
        if days == [1, 7] { return L("周末") }
        return orderedWeekdays.filter(days.contains).map { sym[$0 - 1] }.joined(separator: " ")
    }
    static func day(_ k: DateKey) -> String {
        let f = DateFormatter(); f.locale = AppLanguage.current.locale
        f.setLocalizedDateFormatFromTemplate("yMMMd EEE")
        return f.string(from: cal.date(from: DateComponents(year: k.y, month: k.m, day: k.d, hour: 12)) ?? Date())
    }
}

enum HoursSide { case include, exclude
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
    @Published var allDay = true

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
    func editDate(_ side: HoursSide, _ k: DateKey?, _ ranges: [ClockRange]?) {
        let r = ranges?.first
        day = k.flatMap { Calendar.current.date(from: DateComponents(year: $0.y, month: $0.m, day: $0.d, hour: 12)) } ?? Date()
        allDay = side == .exclude && (r == nil || r == .allDay)
        start = Self.date(r.map { $0 == .allDay ? ClockTime(9) : $0.start } ?? ClockTime(9))
        end = Self.date(r.map { $0 == .allDay ? ClockTime(18) : $0.end } ?? ClockTime(18))
        target = Target(side: side, rule: nil, isDate: true, dateKey: k)
    }
}

/// Pausa 时段 page: master switch, 提醒时段 (include), 免打扰 (exclude). Exclude always wins.
struct SchedulePage: View {
    @ObservedObject var settings: Settings
    @ObservedObject var editor = ScheduleEditor.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("仅在设定时段提醒"), isOn: $settings.schedule.enabled.animation())
            } footer: {
                Text(L("时段外 Pausa 不会计时，菜单栏仍可手动开始休息。免打扰优先于提醒时段。"))
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HoursSection(settings: settings, editor: editor, side: .include,
                         title: L("提醒时段"), addDate: L("添加补班日…"))
            HoursSection(settings: settings, editor: editor, side: .exclude,
                         title: L("免打扰"), addDate: L("添加休息日…"))
        }
        .formStyle(.grouped)
        .sheet(item: $editor.target) { t in
            if t.isDate { DateSheet(settings: settings, editor: editor, t: t) }
            else { RuleSheet(settings: settings, editor: editor, t: t) }
        }
    }
}

private struct HoursSection: View {
    @ObservedObject var settings: Settings
    @ObservedObject var editor: ScheduleEditor
    let side: HoursSide, title: String, addDate: String
    private var set: HoursSet { settings.schedule[keyPath: side.path] }

    var body: some View {
        Section(title) {
            ForEach(set.rules) { r in
                LabeledContent {
                    Toggle("", isOn: Binding(
                        get: { r.enabled },
                        set: { on in
                            if let i = set.rules.firstIndex(where: { $0.id == r.id }) { settings.schedule[keyPath: side.path].rules[i].enabled = on }
                        }).animation())
                        .labelsHidden().toggleStyle(.switch)
                } label: {
                    Button { editor.editRule(side, r) } label: {
                        HStack(spacing: 8) {
                            Text(ScheduleFormat.range(r.start, r.end)).monospacedDigit()
                            Text(ScheduleFormat.summary(r.weekdays)).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(set.dates.keys.sorted { ($0.y, $0.m, $0.d) < ($1.y, $1.m, $1.d) }, id: \.self) { k in
                LabeledContent {
                    Button(L("移除")) { settings.schedule[keyPath: side.path].dates[k] = nil }.buttonStyle(.borderless)
                } label: {
                    Button { editor.editDate(side, k, set.dates[k]) } label: {
                        HStack(spacing: 8) {
                            Text(ScheduleFormat.day(k))
                            Text((set.dates[k] ?? []).map { ScheduleFormat.range($0.start, $0.end) }.joined(separator: ", "))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button(addDate) { editor.editDate(side, nil, nil) }
                Button(L("添加时段…")) { editor.editRule(side, nil) }
            }
        }
        .disabled(!settings.schedule.enabled)
    }
}

private struct SheetButtons: View {
    var onDelete: (() -> Void)?
    let onCancel: () -> Void, onDone: () -> Void
    var doneDisabled = false
    var body: some View {
        HStack {
            if let d = onDelete { Button(L("删除"), role: .destructive, action: d) }
            Spacer()
            Button(L("取消"), action: onCancel).keyboardShortcut(.cancelAction)
            Button(L("完成"), action: onDone).keyboardShortcut(.defaultAction).disabled(doneDisabled)
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
                Section(t.side == .include ? L("提醒时段") : L("免打扰")) {
                    DatePicker(L("开始"), selection: $editor.start, displayedComponents: .hourAndMinute)
                    DatePicker(L("结束"), selection: $editor.end, displayedComponents: .hourAndMinute)
                    LabeledContent(L("重复")) {
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
                    Text(L("结束早于开始：时段跨过午夜。")).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped).scrollDisabled(true)
            SheetButtons(onDelete: existing.map { i in { settings.schedule[keyPath: t.side.path].rules.remove(at: i); editor.target = nil } },
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

private struct DateSheet: View {
    @ObservedObject var settings: Settings
    @ObservedObject var editor: ScheduleEditor
    let t: ScheduleEditor.Target
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(t.side == .include ? L("补班日") : L("休息日")) {
                    DatePicker(L("日期"), selection: $editor.day, displayedComponents: .date)
                    if t.side == .exclude { Toggle(L("全天"), isOn: $editor.allDay) }
                    if t.side == .include || !editor.allDay {
                        DatePicker(L("开始"), selection: $editor.start, displayedComponents: .hourAndMinute)
                        DatePicker(L("结束"), selection: $editor.end, displayedComponents: .hourAndMinute)
                    }
                }
            }
            .formStyle(.grouped).scrollDisabled(true)
            SheetButtons(onDelete: t.dateKey.map { k in { settings.schedule[keyPath: t.side.path].dates[k] = nil; editor.target = nil } },
                         onCancel: { editor.target = nil }, onDone: save)
        }
        .frame(width: 400)
        .environment(\.locale, AppLanguage.current.locale)
    }
    private func save() {
        let k = DateKey(editor.day, cal: Calendar.current)
        if let old = t.dateKey, old != k { settings.schedule[keyPath: t.side.path].dates[old] = nil }
        let r = (t.side == .exclude && editor.allDay) ? ClockRange.allDay
            : ClockRange(ScheduleEditor.clock(editor.start), ScheduleEditor.clock(editor.end))
        settings.schedule[keyPath: t.side.path].dates[k] = [r]
        editor.target = nil
    }
}
