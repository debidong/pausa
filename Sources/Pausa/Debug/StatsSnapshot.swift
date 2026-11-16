#if DEBUG
import AppKit
import SwiftUI
import PausaCore

/// `Pausa --render-stats DIR --lang xx`: renders the redesigned 统计 page offscreen with sample data
/// in Light and Dark mode (today 7D, picked day Thu, 30D trend, first day, empty, widest 12h59m,
/// extreme 24h/16h week, worst 7x24h week, DST 25h day, and the 清除 alert).
/// Verifies KPI tile alignment, trend bar proportions, app progress-bar plumb line, un-clipped skip
/// badges, and Settings window auto-fitting invariants.
enum StatsSnapshot {
    /// Days Tue 10/13 … Mon 10/19 2026: [short completed, long completed, skipped, work minutes].
    static let example = [[9, 3, 1, 282], [8, 2, 4, 318], [9, 3, 0, 240], [7, 2, 1, 210], [2, 0, 0, 46], [5, 1, 0, 102], [11, 3, 3, 282]]
    static let first = [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [3, 1, 0, 85]]
    /// Prototype 「极端一周」: a 24 h day with 70 breaks and a 16 h day.
    static let extreme = [[12, 6, 3, 425], [47, 23, 2, 1440], [32, 16, 0, 960], [11, 5, 2, 410], [3, 1, 0, 85], [0, 0, 0, 0], [4, 2, 1, 120]]
    /// Every day 24 h and 20 breaks.
    static let worst = Array(repeating: [14, 6, 0, 1440], count: 7)

    private static func sampleApps() -> [(name: String, id: String)] {
        func installed(_ id: String) -> Bool {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
        }
        let primary = installed("com.todesktop.230313mzl4w4u92")
            ? ("Cursor", "com.todesktop.230313mzl4w4u92")
            : ("Safari", "com.apple.Safari")
        // Always include "Visual Studio Code" to test long app name + skip badge layout (uses real icon if installed, monogram if not).
        let longEditor = ("Visual Studio Code", "com.microsoft.VSCode")
        let browser = installed("com.google.Chrome")
            ? ("Google Chrome", "com.google.Chrome")
            : ("Finder", "com.apple.finder")
        return [primary, longEditor, browser]
    }

    /// Generates 30 days of synthetic work spans, break records (with uneven realistic stretches on the last day),
    /// and frontmost app usage rows.
    static func rows(_ spec: [[Int]], now: Date, cal: Calendar) -> (breaks: [BreakRecord], work: [WorkSpan], apps: [AppUsageRecord]) {
        guard !spec.isEmpty else { return ([], [], []) }
        var r: [BreakRecord] = [], w: [WorkSpan] = [], apps: [AppUsageRecord] = []
        let today = cal.startOfDay(for: now)
        let catalog = sampleApps()

        // Seed days -29 .. -7 so 30-day trend view is populated when `spec` has 7 days.
        let seedMins = [245, 310, 275, 360, 290, 35, 0, 295, 340, 260, 315, 280, 60, 15, 330, 390, 310, 285, 250, 0, 40, 270, 305]
        let fullSpec: [[Int]]
        if spec.count == 7 && spec != first {
            let prefix = seedMins.map { m -> [Int] in
                m > 0 ? [max(1, m / 32), max(0, m / 95), m > 320 ? 1 : 0, m] : [0, 0, 0, 0]
            }
            fullSpec = prefix + spec
        } else {
            fullSpec = spec
        }

        for (i, d) in fullSpec.enumerated() {
            let day = cal.date(byAdding: .day, value: i - (fullSpec.count - 1), to: today)!
            let work = min(Double(d[3]) * 60, i == fullSpec.count - 1 ? now.timeIntervalSince(today) : .infinity)
            var start = day.addingTimeInterval(d[3] > 600 ? 0 : 9 * 3600)
            if i == fullSpec.count - 1 { start = min(start, now.addingTimeInterval(-work)) }
            if work > 0 { w.append(WorkSpan(start: start, end: start.addingTimeInterval(work))) }

            let done = d[0] + d[1], slots = done + d[2]
            let skipAt: Set<Int> = {
                guard d[2] > 0 else { return [] }
                if d[2] >= 2 && slots >= 6 {
                    // Place two consecutive skips around mid-day so a realistic >40m unbroken stretch appears.
                    let mid = max(2, slots / 2)
                    var out: Set<Int> = [mid, min(slots, mid + 1)]
                    var cursor = 2
                    while out.count < d[2] && cursor <= slots {
                        out.insert(cursor)
                        cursor += 2
                    }
                    return out
                }
                return Set((0..<d[2]).map { (($0 + 1) * slots) / (d[2] + 1) })
            }()
            var n = 0, skipIdx = 0
            for k in 1...max(1, slots) where slots > 0 {
                let at = start.addingTimeInterval(Double(k) * work / Double(slots + 1))
                if skipAt.contains(k) {
                    let target = catalog[min(skipIdx, 1)]
                    skipIdx += 1
                    r.append(BreakRecord(start: at, kind: .short, planned: 20, result: .skipped,
                                         appBundleID: target.id, appName: target.name))
                    continue
                }
                let long = n >= d[0]; n += 1
                r.append(BreakRecord(start: at, kind: long ? .long : .short, planned: long ? 300 : 20, result: .completed))
            }

            if work >= 60 {
                let shares: [Double] = work >= 120 * 60 ? [0.50, 0.31, 0.19] : [0.62, 0.38]
                for (idx, share) in shares.enumerated() {
                    let app = catalog[idx]
                    apps.append(AppUsageRecord(day: day, bundleID: app.id, appName: app.name, seconds: (work * share).rounded()))
                }
            }
        }
        return (r, w, apps)
    }

    @MainActor static func write(to dir: String) -> Bool {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Settings.dryRun = true
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let m = StatsModel.shared
        let cal = Calendar.autoupdatingCurrent
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 15))!
        m.frozen = true; m.calendar = cal; m.now = { now }; m.clearAll = {}; m.range = .week
        var longest = example; longest[6][3] = 12 * 60 + 59
        let lang = AppLanguage.current.rawValue
        var ok = true
        func check(_ n: String, _ c: Bool) { print(c ? "ok   \(n)" : "FAIL \(n)"); ok = ok && c }
        StatsProbe.on = true

        let states: [(String, [[Int]], Int?, StatsModel.RangeMode)] = [
            ("today", example, nil, .week),
            ("day-thu", example, 2, .week),
            ("month-30d", example, nil, .month),
            ("first-day", first, nil, .week),
            ("empty", [], nil, .week),
            ("longest", longest, nil, .week),
            ("extreme", extreme, nil, .week),
            ("worst", worst, nil, .week),
        ]

        // A 25 h day: New York, Sun 2026-11-01 (DST ends).
        var ny = Calendar(identifier: .gregorian); ny.timeZone = TimeZone(identifier: "America/New_York")!
        ny.locale = cal.locale; ny.firstWeekday = cal.firstWeekday
        let nyNow = ny.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 15))!
        var dst = example; dst[4] = [14, 6, 0, 1500]

        for (tag, spec, pick, rangeMode) in states + [("dst-25h", dst, 4, .week)] {
            let (c, n) = tag == "dst-25h" ? (ny, nyNow) : (cal, now)
            m.calendar = c; m.now = { n }; m.range = rangeMode
            let data = rows(spec, now: n, cal: c)
            m.load = { (data.breaks, data.work, nil, data.apps) }
            m.reload()
            m.selectedDay = pick.map { m.days[$0].day }
            for (name, ap) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                StatsProbe.frames = [:]
                let h = SettingsView.contentHeight(.shared, .stats) + 12
                let out = "\(dir)/stats-\(tag)-\(lang)-\(name).png"
                SettingsSnapshot.draw(AnyView(SettingsView(settings: .shared, page: .stats).scrollDisabled(true)),
                                      width: SettingsView.width, height: h, ap, out)
                let f = StatsProbe.frames
                guard name == "light" else { continue }
                if tag == "empty" {
                    check("empty: no KPI tiles", f["num.value.0"] == nil)
                    continue
                }
                if tag == "day-thu" {
                    check("day-thu: 回到今天 button shown when historical day selected", f["header.backToToday"] != nil)
                } else if pick == nil {
                    check("\(tag): 回到今天 hidden on today", f["header.backToToday"] == nil)
                }
                let vals = (0..<4).compactMap { f["num.value.\($0)"] }
                let labs = (0..<4).compactMap { f["num.label.\($0)"] }
                let cols = (0..<4).compactMap { f["num.col.\($0)"] }
                guard vals.count == 4, labs.count == 4, cols.count == 4 else { check("\(tag): KPI probes", false); continue }
                let vy = vals.map(\.maxY), ly = labs.map(\.maxY)
                check("\(tag): KPI value baselines within 1 pt", (vy.max()! - vy.min()!) <= 1)
                check("\(tag): KPI label baselines within 1 pt", (ly.max()! - ly.min()!) <= 1)
                check("\(tag): 4 equal KPI tiles \(cols.map { fmt($0.width) })", (cols.map(\.width).max()! - cols.map(\.width).min()!) <= 0.5)
                let fitsTile = zip(vals, cols).allSatisfy { $0.minX >= $1.minX + 6 && $0.maxX <= $1.maxX - 4 }
                check("\(tag): KPI values fit inside tiles", fitsTile)

                chartChecks(tag, f, m, check)
                appRowChecks(tag, f, m, check)
            }
        }
        m.range = .week
        StatsProbe.on = false

        // Window auto-fit checks: each tab sets the window height to its content, growing and shrinking, top edge & width kept.
        do {
            let key = "PausaStatsRenderCheck"
            NSWindow.removeFrame(usingName: key)
            let (w, tabs) = SettingsTabsController.makeWindow(settings: .shared, onPreview: {}, autosave: key)
            let wasPage = SettingsNav.shared.page
            let chrome = w.frame.height - w.contentLayoutRect.height
            func wantRaw(_ p: SettingsPage) -> CGFloat { chrome + SettingsView.contentHeight(.shared, p, width: w.contentLayoutRect.width) + 1 }
            tabs.select(.general)
            let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 2000, height: 2000)
            SettingsTabsController.visibleHeightOverride = 1200   // isolate from laptop screen bottom clamping
            w.setFrame(NSRect(x: vis.minX + 100, y: vis.maxY - 40 - 420, width: 560, height: 420), display: false)
            let top = w.frame.maxY
            func want(_ p: SettingsPage) -> CGFloat {
                max(SettingsTabsController.minimumFrame(w).height, min(wantRaw(p), SettingsTabsController.maxFittedHeight, 1200))
            }
            let sample = rows(example, now: now, cal: cal)
            m.calendar = cal; m.now = { now }; m.selectedDay = nil; m.range = .week
            m.load = { (sample.breaks, sample.work, nil, sample.apps) }; m.reload()

            tabs.select(.stats)
            let statsH = w.frame.height
            check("统计 sets height \(fmt(statsH)) = content \(fmt(want(.stats))), top kept, width 560",
                  abs(statsH - want(.stats)) <= 0.5 && abs(w.frame.maxY - top) <= 0.5 && w.frame.width == 560)
            for p in [SettingsPage.breaks, .stats] {
                tabs.select(p)
                check("\(p.rawValue): height \(fmt(w.frame.height)) = content \(fmt(want(p))), top kept",
                      abs(w.frame.height - want(p)) <= 0.5 && abs(w.frame.maxY - top) <= 0.5)
            }
            tabs.select(.about)
            check("统计 → 关于 shrinks to \(fmt(w.frame.height)) = content \(fmt(want(.about))), top kept",
                  abs(w.frame.height - want(.about)) <= 0.5 && w.frame.height < statsH && abs(w.frame.maxY - top) <= 0.5)

            SettingsTabsController.visibleHeightOverride = 520
            tabs.select(.stats)
            let area = w.contentLayoutRect.height, page = SettingsView.contentHeight(.shared, .stats, width: w.contentLayoutRect.width)
            check("short screen (520 pt): capped at \(fmt(w.frame.height)), page \(fmt(page)) > area \(fmt(area)) scrolls, top kept",
                  abs(w.frame.height - 520) <= 0.5 && page > area && abs(w.frame.maxY - top) <= 0.5)
            SettingsTabsController.visibleHeightOverride = nil

            tabs.select(.stats)
            m.load = { ([], [], nil, []) }; m.reload()
            let emptyH = w.frame.height
            check("empty 统计: \(fmt(emptyH)) = content \(fmt(want(.stats)))", abs(emptyH - want(.stats)) <= 0.5)
            m.load = { (sample.breaks, sample.work, nil, sample.apps) }; m.reload()
            let dataH = w.frame.height
            check("empty -> data grows \(fmt(emptyH)) -> \(fmt(dataH)) = content \(fmt(want(.stats))), top kept",
                  dataH > emptyH && abs(dataH - want(.stats)) <= 0.5 && abs(w.frame.maxY - top) <= 0.5)
            var resizes = 0
            let obs = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: nil) { _ in resizes += 1 }
            m.reload(); m.reload()
            check("refresh with the same height: no resize (\(resizes))", resizes == 0)
            NotificationCenter.default.removeObserver(obs)
            m.load = { ([], [], nil, []) }; m.reload()
            check("清除 -> empty shrinks \(fmt(dataH)) -> \(fmt(w.frame.height)), top kept",
                  abs(w.frame.height - emptyH) <= 0.5 && abs(w.frame.maxY - top) <= 0.5)
            m.onContentChange = nil
            tabs.select(wasPage); w.setFrameAutosaveName(""); NSWindow.removeFrame(usingName: key); w.close()
        }

        // Plurals in summary, tooltip, and app skip badge.
        do {
            var d = DayStats(day: now); d.taken = 1; d.skipped = 1; d.work = 3600; d.seconds = 20
            var d2 = d; d2.taken = 2; d2.skipped = 0
            let tip1 = StatsText.tip(d, isToday: true), sum1 = StatsText.summary([d]), tip2 = StatsText.tip(d2, isToday: true)
            let sk1 = StatsText.appSkipped(1), sk2 = StatsText.appSkipped(2)
            print("     tip(1): \(tip1)\n     summary(1): \(sum1)\n     skip(1/2): \(sk1) / \(sk2)")
            if lang == "en" {
                check("en plurals: 1 break / 2 breaks, 1 skip / 2 skips",
                      tip1.contains("1\u{00A0}break taken") && sum1.contains("1\u{00A0}break taken")
                      && tip2.contains("2\u{00A0}breaks taken")
                      && sk1 == "1\u{00A0}skip" && sk2 == "2\u{00A0}skips")
            } else if lang == "zh-Hans" {
                check("zh wording: tooltip & skip badge",
                      tip1 == "今天：工作 1\u{00A0}小时，完成 1\u{00A0}次休息，休息 20\u{00A0}秒，跳过 1\u{00A0}次"
                      && sk2 == "跳过\u{00A0}2\u{00A0}次")
            }
        }

        // The 清除 confirmation alert.
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

        // 清除 / 取消 ordering.
        do {
            var log: [String] = []
            let (keepClear, keepLoad) = (m.clearAll, m.load)
            m.clearAll = { log.append("clear") }
            m.finishClear(.alertSecondButtonReturn) { log.append("dismiss") }
            check("清除: alert closed before anything else (\(log))", log == ["dismiss"])
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            check("清除: then data cleared (\(log))", log == ["dismiss", "clear"])
            log = []
            m.finishClear(.alertFirstButtonReturn) { log.append("dismiss") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            check("取消: alert closed, data kept (\(log))", log == ["dismiss"])
            m.clearAll = keepClear; m.load = keepLoad; m.reload()
        }
        print(ok ? "STATSRENDER PASS" : "STATSRENDER FAIL")
        return ok
    }

    @MainActor static func chartChecks(_ tag: String, _ f: [String: CGRect], _ m: StatsModel, _ check: (String, Bool) -> Void) {
        let count = m.days.count
        let cols = (0..<count).compactMap { f["chart.col.\($0)"] }
        guard cols.count == count else { check("\(tag): chart probes (\(cols.count)/\(count))", false); return }
        let bars = (0..<count).map { f["chart.bar.\($0)"] }
        let bw = bars.compactMap { $0?.width }
        let centred = zip(bars, cols).allSatisfy { b, c in b.map { abs($0.midX - c.midX) <= 0.6 } ?? true }
        if let b = bw.first {
            check("\(tag): \(count)D bars \(fmt(b)) pt wide, equal & centred",
                  bw.allSatisfy { abs($0 - b) <= 0.6 } && centred)
        }
        if m.range == .week {
            let tops = (0..<count).map { f["chart.top.\($0)"] }
            let gaps = (0..<(count - 1)).compactMap { i -> CGFloat? in
                guard let a = tops[i], let b = tops[i + 1] else { return nil }
                return b.minX - a.maxX
            }
            if let g = gaps.min() { check("\(tag): top labels ≥ 4 pt apart (min \(fmt(g)))", g >= 4) }
        }
        if tag == "extreme", let a = bars[1], let b = bars[2] {
            check("extreme: 24 h bar \(fmt(a.height)) pt fills 100 pt axis, 16 h bar \(fmt(b.height)) ≈ 2/3",
                  abs(a.height - 100) <= 0.6 && abs(b.height - a.height * 2 / 3) <= 1.2)
        }
        if tag == "dst-25h", let b = bars[4], let t = f["chart.top.4"] {
            let d = m.days[4]
            check("dst-25h: 25 h day (\(fmt(CGFloat(d.work / 3600))) h) caps at 100 pt (\(fmt(b.height))), label \(StatsText.compactBarLabel(d.work) ?? "-") unclipped (\(fmt(t.width)))",
                  abs(b.height - 100) <= 0.6 && abs(d.work - 25 * 3600) < 1 && t.width <= cols[4].width)
        }
    }

    @MainActor static func appRowChecks(_ tag: String, _ f: [String: CGRect], _ m: StatsModel, _ check: (String, Bool) -> Void) {
        let apps = m.selected.apps
        guard !apps.isEmpty else { return }
        let tracks = apps.indices.compactMap { f["app.track.\($0)"] }
        guard tracks.count == apps.count else { check("\(tag): app track probes", false); return }
        let minXs = tracks.map(\.minX), widths = tracks.map(\.width)
        check("\(tag): app progress bars aligned on single plumb line (\(minXs.map(fmt)))",
              (minXs.max()! - minXs.min()!) <= 0.5 && (widths.max()! - widths.min()!) <= 0.5)
        for idx in apps.indices where apps[idx].skipped > 0 {
            if let badge = f["app.badge.\(idx)"] {
                let gapToBar = tracks[idx].minX - badge.maxX
                check("\(tag): app[\(idx)] (\(apps[idx].name)) skip badge un-clipped (\(fmt(gapToBar)) pt before bar)",
                      badge.width >= 30 && gapToBar >= 8)
            } else {
                check("\(tag): app[\(idx)] skip badge probe present", false)
            }
        }
    }

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.1f", v) }
}
#endif
