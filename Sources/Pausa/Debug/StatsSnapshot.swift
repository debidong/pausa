#if DEBUG
import AppKit
import SwiftUI
import PausaCore

/// `Pausa --render-stats DIR --lang xx`: the 统计 page offscreen with sample data (the spec prototype's
/// numbers), light and dark: today, a picked day (Thu), the first day, no data, the widest value
/// (12 小时 59 分钟), the extreme week (24 h / 70 breaks and 16 h), the worst case (seven 24 h days of
/// 20 breaks), and the 清除 alert. No window is ordered in; the user's log is never read or written.
/// Prints the alignment and chart checks it measured on the layout and on the rendered pixels.
enum StatsSnapshot {
    /// Days Tue 10/13 … Mon 10/19 2026: [short completed, long completed, skipped, work minutes].
    static let example = [[12, 6, 3, 425], [14, 6, 1, 460], [9, 4, 4, 380], [11, 5, 2, 410], [3, 1, 0, 85], [0, 0, 0, 0], [4, 2, 1, 120]]
    static let first = [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [3, 1, 0, 85]]
    /// Prototype 「极端一周」: a 24 h day with 70 breaks and a 16 h day.
    static let extreme = [[12, 6, 3, 425], [47, 23, 2, 1440], [32, 16, 0, 960], [11, 5, 2, 410], [3, 1, 0, 85], [0, 0, 0, 0], [4, 2, 1, 120]]
    /// Items 25 / 33: every day 24 h (「24.0 小时」 in all seven columns) and 20 breaks.
    static let worst = Array(repeating: [14, 6, 0, 1440], count: 7)

    /// One work span per day; breaks spread over it like the prototype (skips leave no cut).
    /// Today's span ends by `now` (15:00), so long days start at midnight.
    static func rows(_ spec: [[Int]], now: Date, cal: Calendar) -> ([BreakRecord], [WorkSpan]) {
        var r: [BreakRecord] = [], w: [WorkSpan] = []
        let today = cal.startOfDay(for: now)
        for (i, d) in spec.enumerated() {
            let day = cal.date(byAdding: .day, value: i - (spec.count - 1), to: today)!
            // Today cannot hold more work than has elapsed by `now` (the worst week shows 15.0 today).
            let work = min(Double(d[3]) * 60, i == spec.count - 1 ? now.timeIntervalSince(today) : .infinity)
            var start = day.addingTimeInterval(d[3] > 600 ? 0 : 9 * 3600)
            if i == spec.count - 1 { start = min(start, now.addingTimeInterval(-work)) }
            if work > 0 { w.append(WorkSpan(start: start, end: start.addingTimeInterval(work))) }
            let done = d[0] + d[1], slots = done + d[2]
            let skipAt = Set((0..<d[2]).map { (($0 + 1) * slots) / (d[2] + 1) })
            var n = 0
            for k in 1...max(1, slots) where slots > 0 {
                let at = start.addingTimeInterval(Double(k) * work / Double(slots + 1))
                if skipAt.contains(k) { r.append(BreakRecord(start: at, kind: .short, planned: 20, result: .skipped)); continue }
                let long = n >= d[0]; n += 1
                r.append(BreakRecord(start: at, kind: long ? .long : .short, planned: long ? 300 : 20, result: .completed))
            }
        }
        return (r, w)
    }

    @MainActor static func write(to dir: String) -> Bool {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Settings.dryRun = true
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let m = StatsModel.shared
        let cal = Calendar.autoupdatingCurrent
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 15))!
        m.frozen = true; m.calendar = cal; m.now = { now }; m.clearAll = {}
        var longest = example; longest[6][3] = 12 * 60 + 59
        let lang = AppLanguage.current.rawValue
        var ok = true
        func check(_ n: String, _ c: Bool) { print(c ? "ok   \(n)" : "FAIL \(n)"); ok = ok && c }
        StatsProbe.on = true
        let states: [(String, [[Int]], Int?)] = [("today", example, nil), ("day-thu", example, 2), ("first-day", first, nil),
                                                 ("empty", [], nil), ("longest", longest, nil),
                                                 ("extreme", extreme, nil), ("worst", worst, nil)]
        // A 25 h day: New York, Sun 2026-11-01 (DST ends). The bar caps at 240 pt, the label says 25.0.
        var ny = Calendar(identifier: .gregorian); ny.timeZone = TimeZone(identifier: "America/New_York")!
        ny.locale = cal.locale; ny.firstWeekday = cal.firstWeekday
        let nyNow = ny.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 15))!
        var dst = example; dst[4] = [14, 6, 0, 1500]
        for (tag, spec, pick) in states + [("dst-25h", dst, 4)] {
            let (c, n) = tag == "dst-25h" ? (ny, nyNow) : (cal, now)
            m.calendar = c; m.now = { n }
            let data = rows(spec, now: n, cal: c)
            m.load = { (data.0, data.1, nil) }
            m.reload()
            m.selectedDay = pick.map { m.days[$0].day }
            for (name, ap) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                StatsProbe.frames = [:]
                // fittingSize comes up short for this page (the number card is a GeometryReader): keep slack.
                let h = SettingsView.contentHeight(.shared, .stats) + 80
                let out = "\(dir)/stats-\(tag)-\(lang)-\(name).png"
                SettingsSnapshot.draw(AnyView(SettingsView(settings: .shared, page: .stats).scrollDisabled(true)),
                                      width: SettingsView.width, height: h, ap, out)
                let f = StatsProbe.frames
                if tag != "empty" { cutChecks("\(tag)/\(name)", out, f, m, check) }
                guard name == "light" else { continue }
                if let card = f["data.card"], let b = f["data.button"] {
                    let top = b.minY - card.minY, bottom = card.maxY - b.maxY
                    check("\(tag): 清除数据… centred (top \(fmt(top)) / bottom \(fmt(bottom)), right \(fmt(card.maxX - b.maxX)))",
                          abs(top - bottom) <= 1 && abs(card.maxX - b.maxX - 16) <= 0.5)
                }
                if tag == "empty" { check("empty: no number card", f["num.value.0"] == nil); continue }
                let vals = (0..<4).compactMap { f["num.value.\($0)"] }, labs = (0..<4).compactMap { f["num.label.\($0)"] }
                let cols = (0..<4).compactMap { f["num.col.\($0)"] }
                guard vals.count == 4, labs.count == 4, cols.count == 4 else { check("\(tag): probes", false); continue }
                let vy = vals.map(\.maxY), ly = labs.map(\.maxY)
                check("\(tag): number baselines (bottoms \(vy.map(fmt))) within 1 pt", (vy.max()! - vy.min()!) <= 1)
                check("\(tag): name baselines (bottoms \(ly.map(fmt))) within 1 pt", (ly.max()! - ly.min()!) <= 1)
                check("\(tag): equal columns \(cols.map { fmt($0.width) })", (cols.map(\.width).max()! - cols.map(\.width).min()!) <= 0.5)
                let margins = zip(vals, cols).map { min($0.minX - $1.minX, $1.maxX - $0.maxX) }
                chartChecks(tag, f, m, check)
                if tag == "longest" {
                    let wide = StatsValue.width(StatsText.durationPieces(StatsNumbers.widest), size: 19)
                    print("     widest at 19 pt: \(fmt(wide)) pt -> \(fmt((cols[0].width - wide) / 2)) pt each side; numbers drawn at \(fmt(StatsNumbers.numberSize(column: cols[0].width, widestAt19: wide))) pt")
                    check("longest: 12 h 59 min leaves ≥ 8 pt each side (\(fmt(margins[0])))", margins[0] >= 8)
                }
            }
        }
        StatsProbe.on = false
        // Item 33: switching to 统计 grows a small window to the page (worst week loaded), top edge kept.
        // The window is never ordered in and uses a throwaway autosave key, removed afterwards.
        do {
            let key = "PausaStatsRenderCheck"
            NSWindow.removeFrame(usingName: key)
            let (w, tabs) = SettingsTabsController.makeWindow(settings: .shared, onPreview: {}, autosave: key)
            let wasPage = SettingsNav.shared.page
            tabs.select(.general)
            let top = w.frame.maxY
            w.setFrame(NSRect(x: 100, y: top - 420, width: 500, height: 420), display: false)
            tabs.select(.stats)
            let need = SettingsView.contentHeight(.shared, .stats)
            let cap = (w.screen ?? NSScreen.main)?.visibleFrame.height ?? .infinity
            let fits = w.contentLayoutRect.height >= need || w.frame.height >= cap - 0.5
            check("window grows to 统计 (page \(fmt(need)) pt, area \(fmt(w.contentLayoutRect.height)) pt, frame \(fmt(w.frame.height)), top kept)",
                  fits && abs(w.frame.maxY - top) <= 0.5)
            let grown = w.frame
            tabs.select(.about)
            check("other tabs keep the (grown) size", w.frame.size == grown.size)
            tabs.select(wasPage); w.setFrameAutosaveName(""); NSWindow.removeFrame(usingName: key); w.close()
        }
        // The 清除 confirmation (its content view; the alert's own window frame is real-Mac only).
        for (name, ap) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let (a, cancel) = m.makeClearAlert()
            a.window.appearance = NSAppearance(named: ap)
            a.layout()
            guard let v = a.window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let out = "\(dir)/stats-clear-alert-\(lang)-\(name).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)); print(out)
            if name == "light" {
                let clear = a.buttons[1]
                check("alert: 取消 is default (Return)", cancel.keyEquivalent == "\r" && a.buttons[0] === cancel)
                check("alert: 清除 destructive, no key", clear.hasDestructiveAction && clear.keyEquivalent.isEmpty)
            }
        }
        print(ok ? "STATSRENDER PASS" : "STATSRENDER FAIL")
        return ok
    }

    /// Layout: items 16–18, 25, 26, 33 and the label's distance to the card's top edge.
    @MainActor static func chartChecks(_ tag: String, _ f: [String: CGRect], _ m: StatsModel, _ check: (String, Bool) -> Void) {
        let cols = (0..<7).compactMap { f["chart.col.\($0)"] }
        guard cols.count == 7 else { check("\(tag): chart probes", false); return }
        let bars = (0..<7).map { f["chart.bar.\($0)"] }, tops = (0..<7).map { f["chart.top.\($0)"] }
        let counts = (0..<7).map { f["chart.count.\($0)"] }
        let bw = bars.compactMap { $0?.width }
        let centred = zip(bars, cols).allSatisfy { b, c in b.map { abs($0.midX - c.midX) <= 0.5 } ?? true }
        if let b = bw.first {
            let share = b / cols[0].width
            check("\(tag): bars \(fmt(b)) of \(fmt(cols[0].width)) pt (\(Int((share * 100).rounded())) %), equal, centred",
                  share >= 0.70 && share <= 0.75 && bw.allSatisfy { abs($0 - b) <= 0.5 } && centred)
        }
        let gaps = (0..<6).compactMap { i -> CGFloat? in
            guard let a = tops[i], let b = tops[i + 1] else { return nil }; return b.minX - a.maxX }
        if let g = gaps.min() { check("\(tag): top labels ≥ 4 pt apart (min \(fmt(g)))", g >= 4) }
        let over = zip(counts, cols).compactMap { c, col in c.map { $0.width - col.width } }
        if let o = over.max() { check("\(tag): count line fits its column (spare \(fmt(-o)))", o <= 0) }
        let tallest = bars.compactMap { $0?.height }.max() ?? 0
        let plotTop = cols[0].minY - 14   // the card's top edge: the chart sits 14 pt into it
        if let t = tops.compactMap({ $0 }).min(by: { $0.minY < $1.minY }) {
            check("\(tag): top label \(fmt(t.minY - plotTop)) pt below the card edge (≥ 8)", t.minY - plotTop >= 8)
        }
        let maxWork = m.days.map(\.work).max() ?? 0
        check("\(tag): tallest bar \(fmt(tallest)) pt = StatsChart.barHeight(longest) \(fmt(CGFloat(StatsChart.barHeight(work: maxWork, longest: maxWork))))",
              abs(tallest - CGFloat(StatsChart.barHeight(work: maxWork, longest: maxWork))) <= 1)
        if tag == "today", let a = bars[2], let b = bars[1] {   // Thu 380 min vs Wed 460 min (the longest)
            check("today: Thu / Wed = \(fmt(a.height)) / \(fmt(b.height)) ≈ 380 / 460", abs(a.height - b.height * 380 / 460) <= 1)
        }
        if tag == "dst-25h", let b = bars[4], let t = tops[4], let card = cols.first {
            let d = m.days[4]
            check("dst-25h: 25 h day (\(fmt(CGFloat(d.work / 3600))) h) caps at \(fmt(b.height)) pt, label \(StatsText.barLabel(d.work) ?? "-") unclipped (\(fmt(t.width)) pt in \(fmt(card.width)))",
                  abs(b.height - 240) <= 0.5 && abs(d.work - 25 * 3600) < 1 && t.width <= card.width)
        }
        if tag == "extreme", let a = bars[1], let b = bars[2] {
            check("extreme: 24 h day \(fmt(a.height)) pt fills the axis, 16 h day \(fmt(b.height)) = 2/3 of it", abs(b.height - a.height * 2 / 3) <= 1)
        }
    }

    /// Pixels: every completed break is exactly one cut (items 21, 23), each a clean 1 pt run of card
    /// colour (no half-tone smear), at the work time before the break (item 22).
    @MainActor static func cutChecks(_ tag: String, _ png: String, _ f: [String: CGRect], _ m: StatsModel, _ check: (String, Bool) -> Void) {
        guard let data = FileManager.default.contents(atPath: png), let rep = NSBitmapImageRep(data: data),
              let col0 = f["chart.col.0"] else { return }
        let sc = CGFloat(rep.pixelsWide) / SettingsView.width
        func px(_ x: CGFloat, _ y: CGFloat) -> NSColor? { rep.colorAt(x: Int(x * sc), y: Int(y * sc))?.usingColorSpace(.deviceRGB) }
        func near(_ a: NSColor, _ b: NSColor) -> Bool {
            abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) < 0.03
        }
        _ = col0
        var wrong: [String] = [], smears = 0, posErr: CGFloat = 0
        let longest = m.days.map(\.work).max() ?? 0
        for i in 0..<7 {
            guard let b = f["chart.bar.\(i)"], let bg = px(b.minX - 3, b.maxY - 1) else { continue }
            let x = Int(b.midX * sc)
            var runs: [(start: Int, len: Int)] = [], y = Int((b.minY * sc).rounded()) + Int(sc), end = Int((b.maxY * sc).rounded())
            var inside = false, smeared = 0
            while y < end {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { y += 1; continue }
                let cut = near(c, bg)
                if cut { if inside { runs[runs.count - 1].len += 1 } else { runs.append((y, 1)) }; inside = true } else { inside = false }
                // a pixel that is neither bar nor card: a half-tone edge
                if !cut, let above = rep.colorAt(x: x, y: y - 1)?.usingColorSpace(.deviceRGB), near(above, bg),
                   let below = rep.colorAt(x: x, y: y + 1)?.usingColorSpace(.deviceRGB), !near(below, c) { smeared += 1 }
                y += 1
            }
            smears += smeared
            // Expected runs: the drawn cuts, where cuts closer than 1 pt + 1 px share a run (Steve: same row = one).
            let rows = StatsWeekChart.cutRows(m.days[i], longest: longest, scale: sc).sorted()
            var want = 0, single = 0, prev = -CGFloat.infinity, alone = true
            for (k, c) in rows.enumerated() {
                if c - prev > 1 + 0.5 / sc { want += 1; if k > 0, alone { single += 1 }; alone = true } else { alone = false }
                prev = c
            }
            if !rows.isEmpty, alone { single += 1 }
            if runs.count != want { wrong.append("day \(i): \(runs.count) runs / \(want) expected (\(m.days[i].taken) breaks)") }
            let clean = runs.filter { $0.len == Int(sc) }.count
            if clean < single { wrong.append("day \(i): \(clean) exact 1 pt runs / \(single) lone cuts \(runs.map(\.len))") }
            if let first = m.days[i].gaps.first, let r = runs.last {   // runs are top-down: the last is the lowest cut
                let fromBottom = b.maxY - CGFloat(r.start + r.len) / sc
                let expected = CGFloat(StatsChart.barHeight(work: first, longest: longest)) - 0.5
                posErr = max(posErr, abs(fromBottom - expected))
            }
        }
        check("\(tag): one clean 1 pt cut per completed break \(wrong.isEmpty ? "" : wrong.joined(separator: "; "))", wrong.isEmpty)
        check("\(tag): lowest cut sits at its work time (max error \(fmt(posErr)) pt)", posErr <= 1)
        if smears > 0 { print("     \(tag): \(smears) half-tone pixels next to cuts") }
    }

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.1f", v) }
}
#endif
