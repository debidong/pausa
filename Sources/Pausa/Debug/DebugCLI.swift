#if DEBUG
import AppKit
import PausaCore

/// Debug entry points for Detection/ and Overlay/ (no app shell needed).
///   --debug-detect [seconds]        print detector state every second (default 10s)
///   --debug-short [seconds]         show the short break (default 5s), then exit
///   --debug-long [seconds]          show the long break (default 8s), then exit
///   --debug-about [seconds]         show the About panel (default 8s), then exit
///   --debug-render-long <dir> [--night] [--oil off|light|medium]  long break per theme, 16:10 + 16:9, countdown 2:47
///   --debug-render-quotes <dir> --lang <code>  short + long break with the longest quote
///   --debug-selftest-spacehold      Space/repeat handling with synthesized events (no window)
///   --debug-selftest-break-key      SHOWS short + long breaks (2 s each) and asserts the break window is key; dev Macs only
///   --debug-render-glass <dir>     PROTOTYPE: Liquid Glass vs fallback break screens (no window)
///   --debug-render-prebreak <dir>  pre-break panel: zh/en × notch/no notch × short/short-used-up/long/90-min, 16 PNGs at 2x (no window)
///   --debug-render-pill <dir>      cursor pill: prints a pointer to scripts/render-pill.sh (the pill is a real window now)
///   --debug-selftest-prebreak      pill geometry, button sets, row wrapping, notch placement (no window)
///   --debug-show-prebreak [--screen builtin|external|pointer] [--kind short|long|hard] [--used] [--from N] [--hold S] [--lang code]
///                                  SHOWS the real panel counting down from N (default 30) for S seconds; dev Macs only, ask first.
///                                  PAUSA_CAPTURABLE=1 lets screencapture see it.
///   --debug-render-short <out.png> [sample.png]  offscreen render of the short-break blur [--opacity 0-1]
enum DebugCLI {
    static func handles(_ args: [String]) -> Bool {
        args.contains { $0.hasPrefix("--debug-") }
    }

    static func run(_ args: [String]) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        func num(after flag: String, _ def: Double) -> Double {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count, let v = Double(args[i + 1]) else { return def }
            return v
        }
        let detector = PauseDetector()
        let overlay = BreakOverlayController()
        var keep: [AnyObject] = [detector, overlay]
        _ = keep

        if let i = args.firstIndex(of: "--debug-render-glass"), i + 1 < args.count {
            MainActor.assumeIsolated { GlassProto.renderAll(URL(fileURLWithPath: args[i + 1])) }; exit(0)
        }
        if args.contains("--debug-selftest-spacehold") {
            // Round 7b: repeats are consumed (no beep) and never start a hold; a first press does after the grace.
            func key(_ code: UInt16, _ down: Bool, repeat r: Bool) -> NSEvent {
                NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
                                 windowNumber: 0, context: nil, characters: code == 49 ? " " : "a",
                                 charactersIgnoringModifiers: code == 49 ? " " : "a", isARepeat: r, keyCode: code)!
            }
            let hold = HoldToSkip()
            let old = ProcessInfo.processInfo.systemUptime - 10
            var ok = true
            func check(_ name: String, _ c: Bool) { print(c ? "ok   \(name)" : "FAIL \(name)"); ok = ok && c }
            check("repeat space consumed", SpaceHold.handle(key(49, true, repeat: true), hold: hold, shownAt: old))
            check("repeat space starts nothing", hold.progress == 0)
            check("repeat other key consumed", SpaceHold.handle(key(0, true, repeat: true), hold: hold, shownAt: old))
            check("plain other key passes", !SpaceHold.handle(key(0, true, repeat: false), hold: hold, shownAt: old))
            check("space in grace consumed", SpaceHold.handle(key(49, true, repeat: false), hold: hold, shownAt: ProcessInfo.processInfo.systemUptime))
            check("first space consumed", SpaceHold.handle(key(49, true, repeat: false), hold: hold, shownAt: old))
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            check("hold progressing", hold.progress > 0.15 && hold.progress < 0.35)
            check("release consumed", SpaceHold.handle(key(49, false, repeat: false), hold: hold, shownAt: old))
            check("release resets to zero", hold.progress == 0)
            check("duration is 2 s", HoldToSkip.duration == 2.0)
            // mustNotDefer long break: the window has no hold, Space is swallowed (no beep) and skips nothing.
            check("locked: space consumed", SpaceHold.handle(key(49, true, repeat: false), hold: nil, shownAt: old))
            check("locked: repeat consumed", SpaceHold.handle(key(49, true, repeat: true), hold: nil, shownAt: old))
            check("locked: release consumed", SpaceHold.handle(key(49, false, repeat: false), hold: nil, shownAt: old))
            check("locked: overlay passes no hold", BreakOverlayController.holdFor(mustNotDefer: true, HoldToSkip()) == nil)
            // Mouse long-press on the capsule: same HoldToSkip, so same duration as Space (within 0.1 s).
            func timeToSkip(_ start: (HoldToSkip) -> Void) -> Double? {
                let h = HoldToSkip(); var at: Double?
                let t0 = ProcessInfo.processInfo.systemUptime
                h.onComplete = { at = ProcessInfo.processInfo.systemUptime - t0 }
                start(h)
                RunLoop.main.run(until: Date().addingTimeInterval(HoldToSkip.duration + 0.4))
                return at
            }
            var c = false
            let tSpace = timeToSkip { _ = SpaceHold.handle(key(49, true, repeat: false), hold: $0, shownAt: old) }
            let tMouse = timeToSkip { PointerHold.changed($0, inside: true, cancelled: &c) }
            print("     space \(tSpace.map { String(format: "%.3f", $0) } ?? "-") s, mouse \(tMouse.map { String(format: "%.3f", $0) } ?? "-") s")
            check("mouse vs space within 0.1 s", tSpace != nil && tMouse != nil && abs(tSpace! - tMouse!) <= 0.1)
            do {   // half press, released: no skip, fill back to 0
                let h = HoldToSkip(); var skipped = false; h.onComplete = { skipped = true }; c = false
                PointerHold.changed(h, inside: true, cancelled: &c)
                RunLoop.main.run(until: Date().addingTimeInterval(1.0))
                PointerHold.ended(h, cancelled: &c)
                RunLoop.main.run(until: Date().addingTimeInterval(1.5))
                check("mouse half press: no skip", !skipped)
                check("mouse half press: retracted", h.progress == 0)
            }
            do {   // drag out cancels; coming back in during the same press does not restart
                let h = HoldToSkip(); var skipped = false; h.onComplete = { skipped = true }; c = false
                PointerHold.changed(h, inside: true, cancelled: &c)
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                PointerHold.changed(h, inside: false, cancelled: &c)
                PointerHold.changed(h, inside: true, cancelled: &c)
                RunLoop.main.run(until: Date().addingTimeInterval(2.2))
                check("mouse drag out: no skip", !skipped)
                PointerHold.ended(h, cancelled: &c)
            }
            do {   // forced long break: no hold reaches the view or the key path
                let forced = BreakOverlayController.holdFor(mustNotDefer: true, HoldToSkip())
                c = false
                PointerHold.changed(forced, inside: true, cancelled: &c)
                check("locked: mouse has no hold", forced == nil)
            }
            // Capsule copy + keycap and the short glass prompt: present in all 8 locales, one line.
            for (lang, t) in L10nTables.all.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                let src = L10nTables.zhHans
                func v(_ k: String) -> String { t[k] ?? src[k] ?? "" }
                func w(_ str: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
                    (str as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
                }
                let (pre, post) = HoldCapsule.split(v("break.holdToSkip"))
                let gaps = CGFloat((pre.isEmpty ? 0 : 1) + (post.isEmpty ? 0 : 1)) * 4
                let cap = w(pre, 13, .medium) + w(post, 13, .medium) + gaps + w(v("key.space"), 12, .medium) + 10 + 32
                let shortW = w(v("break.short.hint"), 108 * 0.7, .semibold)
                print("     \(lang.rawValue): capsule \(Int(cap)) pt, short hint \(Int(shortW)) pt")
                check("\(lang.rawValue): keys present", v("break.holdToSkip").contains("%@") && !v("key.space").isEmpty && !v("break.short.hint").isEmpty)
                check("\(lang.rawValue): one line on a 1280-pt screen", cap < 600 && shortW < 1200)
            }
            // Forced long break (past the hard line), end to end through the same wiring the overlay uses.
            MainActor.assumeIsolated {
                let real = HoldToSkip(); var skipped = false; real.onComplete = { skipped = true }
                let forced = BreakOverlayController.holdFor(mustNotDefer: true, real)
                let view = LongBreakView(countdown: Countdown(total: 300, onDone: {}), showControls: true, onSnooze: { _ in },
                                         hold: forced, locked: true)
                print("[forced] hold passed to window/view: \(forced == nil ? "nil" : "HoldToSkip")")
                print("[forced] skip capsule shown: \(view.showsSkipCapsule)")
                let t0 = ProcessInfo.processInfo.systemUptime
                print("[forced] Space down consumed=\(SpaceHold.handle(key(49, true, repeat: false), hold: forced, shownAt: old))")
                c = false
                PointerHold.changed(forced, inside: true, cancelled: &c)
                print("[forced] mouse long-press begun on capsule area (hold=\(forced == nil ? "nil" : "set"))")
                RunLoop.main.run(until: Date().addingTimeInterval(HoldToSkip.duration + 1))
                print(String(format: "[forced] after %.2f s held: skipped=%@ progress=%.2f", ProcessInfo.processInfo.systemUptime - t0, skipped ? "true" : "false", real.progress))
                _ = SpaceHold.handle(key(49, false, repeat: false), hold: forced, shownAt: old)
                PointerHold.ended(forced, cancelled: &c)
                let open = LongBreakView(countdown: Countdown(total: 300, onDone: {}), showControls: true, onSnooze: { _ in },
                                         hold: BreakOverlayController.holdFor(mustNotDefer: false, real), locked: false)
                print("[normal] skip capsule shown: \(open.showsSkipCapsule)")
                check("forced: capsule hidden", !view.showsSkipCapsule)
                check("forced: neither Space nor mouse skipped", !skipped && real.progress == 0)
                check("normal: capsule shown", open.showsSkipCapsule)
            }
            print(ok ? "SPACEHOLD PASS" : "SPACEHOLD FAIL"); exit(ok ? 0 : 1)
        }
        if args.contains("--debug-selftest-settings-window") {
            // Round 7c (j): window built but never ordered in; its own autosave key, removed afterwards.
            Settings.dryRun = true
            let key = "PausaSettingsFrame.selftest"
            NSWindow.removeFrame(usingName: key)
            MainActor.assumeIsolated {
                var ok = true
                func check(_ n: String, _ c: Bool) { print(c ? "ok   \(n)" : "FAIL \(n)"); ok = ok && c }
                SettingsNav.shared.page = .breaks   // dry run: not persisted
                var (w, tabs) = SettingsTabsController.makeWindow(settings: .shared, onPreview: {}, autosave: key)
                let maxH = min(SettingsTabsController.maxFittedHeight, (w.screen ?? NSScreen.main)?.visibleFrame.height ?? 10000)
                check("first open on 休息: 500 x \(Int(maxH)) (\(w.frame.size))", w.frame.width == 500 && abs(w.frame.height - maxH) <= 0.5)
                if let sc = w.screen ?? NSScreen.main {
                    check("centred", abs(w.frame.midX - sc.visibleFrame.midX) < 2)
                }
                check("min frame 500x420 (\(SettingsTabsController.minimumFrame(w)))", SettingsTabsController.minimumFrame(w) == NSSize(width: 500, height: 420))
                check("resizable", w.styleMask.contains(.resizable))
                // A mouse drag obeys constraints (setFrame doesn't), so no view may carry a required fixed size.
                func fixedSizeConstraints() -> [String] {
                    w.contentView?.layoutSubtreeIfNeeded()
                    var out: [String] = [], vs: [NSView] = w.contentView.map { [$0] } ?? []
                    while let v = vs.popLast() {
                        if v.className.contains("HostingView") || v is NSTabView || v === w.contentView {
                            for c in v.constraints where c.secondItem == nil && c.relation == .equal && c.priority == .required && !String(describing: type(of: c)).contains("AutoresizingMask")
                                && (c.firstAttribute == .width || c.firstAttribute == .height) {
                                out.append("\(type(of: v)) \(c.firstAttribute == .width ? "W" : "H")=\(c.constant) [\(type(of: c)) id=\(c.identifier ?? "-") tamic=\(v.translatesAutoresizingMaskIntoConstraints)]")
                            }
                        }
                        if v is NSTabView || v === w.contentView { vs.append(contentsOf: v.subviews) }
                    }
                    // Smallest size the content's own constraints allow must fit inside the 500 x 420 minimum.
                    if let cv = w.contentView {
                        let fit = cv.fittingSize, minC = w.contentMinSize
                        if fit.width > minC.width + 0.5 || fit.height > minC.height + 0.5 { out.append("fittingSize \(fit) > \(minC)") }
                    }
                    return out
                }
                let fixed = fixedSizeConstraints()
                check("drag not blocked: no required fixed size \(fixed)", fixed.isEmpty)
                // Both axes resize and nothing in the content pushes back (layout runs after each setFrame).
                for sz in [NSSize(width: 700, height: 900), NSSize(width: 500, height: 420), NSSize(width: 1200, height: 1000)] {
                    w.setFrame(NSRect(origin: w.frame.origin, size: sz), display: false)
                    w.contentView?.layoutSubtreeIfNeeded()
                    check("setFrame \(sz) reads back (\(w.frame.size))", w.frame.size == sz)
                }
                let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 2000, height: 2000)
                w.setFrame(NSRect(x: vis.minX + 50, y: vis.maxY - 40 - 600, width: 900, height: 600), display: false)
                // Stats items 28/33 (Steve): a tab switch sets the height to the page, keeps width and top edge.
                var top = w.frame.maxY
                for p in [SettingsPage.about, .general, .stats, .breaks, .about] {
                    tabs.select(p)
                    let need = w.frame.height - w.contentLayoutRect.height + SettingsView.contentHeight(.shared, p, width: w.contentLayoutRect.width) + 1
                    let cap = (w.screen ?? NSScreen.main)?.visibleFrame.height ?? .greatestFiniteMagnitude
                    let h = max(SettingsTabsController.minimumFrame(w).height, min(need, SettingsTabsController.maxFittedHeight, cap))
                    let capped = min(need, SettingsTabsController.maxFittedHeight) > cap   // screen-capped: moves up only as far as it must
                    check("\(p.rawValue) fits its page: 900 x \(Int(h)) (\(w.frame.size)), \(capped ? "capped, on screen" : "top kept")",
                          w.frame.width == 900 && abs(w.frame.height - h) <= 0.5
                          && (capped ? w.frame.maxY <= vis.maxY + 0.5 && w.frame.minY >= vis.minY - 0.5 : abs(w.frame.maxY - top) <= 0.5))
                    top = w.frame.maxY
                    let f = fixedSizeConstraints()
                    check("\(p.rawValue) drag not blocked \(f)", f.isEmpty)
                }
                check("min frame after switches (\(SettingsTabsController.minimumFrame(w)))", SettingsTabsController.minimumFrame(w) == NSSize(width: 500, height: 420))
                w.saveFrame(usingName: key)   // what AppKit's autosave does on close/quit
                w.close()
                (w, tabs) = SettingsTabsController.makeWindow(settings: .shared, onPreview: {}, autosave: key)
                check("reopen keeps width 900, fitted height (\(w.frame.size))", w.frame.width == 900)
                // Steve's numbers (500 wide, the sample week loaded): height = min(content, 880, screen).
                do {
                    let m = StatsModel.shared, cal = Calendar.autoupdatingCurrent
                    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 15))!
                    let data = StatsSnapshot.rows(StatsSnapshot.example, now: now, cal: cal)
                    m.frozen = true; m.calendar = cal; m.now = { now }; m.load = { (data.0, data.1, nil) }; m.reload()
                    let vis = (w.screen ?? NSScreen.main)!.visibleFrame
                    w.setFrame(NSRect(x: vis.minX + 50, y: vis.maxY - 40 - 600, width: 500, height: 600), display: false)
                    let top = w.frame.maxY, lang = AppLanguage.current.rawValue
                    @MainActor func page(_ p: SettingsPage) -> CGFloat { SettingsView.contentHeight(.shared, p, width: w.contentLayoutRect.width) }
                    tabs.select(.breaks)
                    check("休息: 880 (\(w.frame.height)), page \(page(.breaks)) > area \(w.contentLayoutRect.height) scrolls, top kept",
                          w.frame.height == 880 && page(.breaks) > w.contentLayoutRect.height && abs(w.frame.maxY - top) <= 0.5)
                    // en 统计 is 839 at 500 wide (820 at 560, where the data-card line fits on one line).
                    let statsWant: CGFloat? = ["zh-Hans": 806, "en": 839][lang], aboutWant: CGFloat? = ["zh-Hans": 448, "en": 462][lang]
                    tabs.select(.stats)
                    check("统计: \(w.frame.height) (expected \(statsWant.map { "\(Int($0))" } ?? "-")), shown fully, top kept",
                          (statsWant.map { w.frame.height == $0 } ?? true) && page(.stats) <= w.contentLayoutRect.height && abs(w.frame.maxY - top) <= 0.5)
                    tabs.select(.about)
                    check("关于: \(w.frame.height) (expected \(aboutWant.map { "\(Int($0))" } ?? "-")), top kept",
                          (aboutWant.map { w.frame.height == $0 } ?? true) && abs(w.frame.maxY - top) <= 0.5)
                    SettingsTabsController.visibleHeightOverride = 520
                    tabs.select(.stats)
                    check("520 pt screen: 统计 capped at 520 (\(w.frame.height)), scrolls", w.frame.height == 520 && page(.stats) > w.contentLayoutRect.height)
                    SettingsTabsController.visibleHeightOverride = nil
                    m.onContentChange = nil
                }
                NSWindow.removeFrame(usingName: key)
                print(ok ? "SETTINGSWINDOW PASS" : "SETTINGSWINDOW FAIL"); exit(ok ? 0 : 1)
            }
        }
        if let i = args.firstIndex(of: "--debug-selftest-settings-minh"), i + 1 < args.count {
            // Settings at the 500 x 420 minimum: the page starts at the tab bar's bottom edge and its top
            // (first section title + the gap above it) is identical to the 809-tall layout; back at 809 the
            // page is pixel-identical to before. Window never ordered in; its own autosave key.
            Settings.dryRun = true
            let out = URL(fileURLWithPath: args[i + 1])
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                var ok = true
                func check(_ n: String, _ c: Bool) { print(c ? "ok   \(n)" : "FAIL \(n)"); ok = ok && c }
                let key = "PausaSettingsFrame.selftest-minh"
                NSWindow.removeFrame(usingName: key)
                let (w, tabs) = SettingsTabsController.makeWindow(settings: .shared, onPreview: {}, autosave: key)
                w.appearance = NSAppearance(named: .aqua)
                func size(_ h: CGFloat) {
                    w.setFrame(NSRect(origin: w.frame.origin, size: NSSize(width: 500, height: h)), display: true)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                    w.contentView?.layoutSubtreeIfNeeded(); w.contentView?.display()
                }
                func snap(_ p: SettingsPage, _ tag: String) -> NSBitmapImageRep? {
                    guard let v = tabs.tabViewItems[SettingsPage.allCases.firstIndex(of: p)!].viewController?.view,
                          let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(p.rawValue)-\(tag).png"))
                    return rep
                }
                /// Rows 0..<rows (top of the page, in pixels) equal in both bitmaps.
                /// `skipRight` px at the right edge are the scroller, whose thumb length depends on the height.
                func sameTop(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, rows: Int, skipRight: Int = 0) -> Bool {
                    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh >= rows, b.pixelsHigh >= rows else { return false }
                    for y in stride(from: 0, to: rows, by: 1) { for x in stride(from: 0, to: a.pixelsWide - skipRight, by: 2) {
                        if a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { return false } } }
                    return true
                }
                for p in [SettingsPage.breaks, .general, .about] {
                    tabs.select(p)
                    size(809)
                    guard let tall = snap(p, "809-before") else { check("\(p.rawValue) snapshot", false); continue }
                    size(420)
                    let v = tabs.tabViewItems[SettingsPage.allCases.firstIndex(of: p)!].viewController!.view
                    let layout = w.contentLayoutRect
                    let pageInWindow = v.convert(v.bounds, to: nil)
                    check("\(p.rawValue) page top = tab bar bottom (\(pageInWindow.maxY) vs \(layout.maxY))", abs(pageInWindow.maxY - layout.maxY) < 0.5)
                    guard let short = snap(p, "420") else { continue }
                    // Top 140 pt: the gap and the first section title (and its first row) unchanged.
                    let rows = Int(140 * CGFloat(short.pixelsHigh) / v.bounds.height)
                    check("\(p.rawValue) top \(rows) px at 420 identical to 809 (scroller strip excluded)", sameTop(tall, short, rows: rows, skipRight: short.pixelsWide * 20 / 500))
                    size(809)
                    guard let again = snap(p, "809-after") else { continue }
                    check("\(p.rawValue) 809 after = before (pixel)", sameTop(tall, again, rows: tall.pixelsHigh))
                }
                NSWindow.removeFrame(usingName: key)
                print(ok ? "SETTINGSMINH PASS" : "SETTINGSMINH FAIL"); exit(ok ? 0 : 1)
            }
        }
        if args.contains("--debug-selftest-random-theme") {
            // 随机: never repeats the previous scene, covers all four; old 跟随系统 migrates to 随机.
            var ok = true
            func check(_ n: String, _ c: Bool) { print(c ? "ok   \(n)" : "FAIL \(n)"); ok = ok && c }
            var last: ThemeChoice? = nil, seen = Set<ThemeChoice>(), repeats = 0
            for _ in 0..<2000 { let t = RandomScene.pick(after: last); if t == last { repeats += 1 }; seen.insert(t); last = t }
            check("no repeat in 2000 picks (\(repeats))", repeats == 0)
            check("all scenes seen \(seen.count)", seen == Set(ThemeChoice.scenes))
            check("random never picked as a scene", !seen.contains(.random))
            check("system -> random", ThemeChoice.migrated("system") == .random)
            check("ocean kept", ThemeChoice.migrated("ocean") == .ocean)
            check("missing -> random", ThemeChoice.migrated(nil) == .random)
            check("invalid -> random", ThemeChoice.migrated("bogus") == .random)
            print(ok ? "RANDOMTHEME PASS" : "RANDOMTHEME FAIL"); exit(ok ? 0 : 1)
        }
        if args.contains("--debug-selftest-shortkey") {
            // Round 7c root cause: can the short-break panel (same class + flags as makeCapsule) become key
            // while another app is active? Off-screen and fully transparent, so nothing is ever visible;
            // focus goes back to the previous app at the end.
            Task { @MainActor in
                let prev = NSWorkspace.shared.frontmostApplication
                func probe(ignoresMouse: Bool, activate: Bool) async -> (Bool, Bool) {
                    let p = ShortBreakPanel(contentRect: NSRect(x: -30000, y: -30000, width: 200, height: 100),
                                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    p.level = .statusBar + 1
                    p.ignoresMouseEvents = ignoresMouse
                    p.isOpaque = false; p.backgroundColor = .clear; p.alphaValue = 0
                    p.animationBehavior = .none
                    if activate { NSApp.activate(ignoringOtherApps: true) }
                    p.orderFrontRegardless()
                    p.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    let r = (p.isKeyWindow, NSApp.isActive)
                    p.orderOut(nil)
                    prev?.activate(options: [])
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    return r
                }
                for (im, act) in [(true, false), (false, false), (true, true)] {
                    let (key, active) = await probe(ignoresMouse: im, activate: act)
                    print("ignoresMouseEvents=\(im) activate=\(act): isKeyWindow=\(key) appActive=\(active)")
                }
                exit(0)
            }
            app.run(); exit(0)
        }
        if args.contains("--debug-show-prebreak") {
            func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
            let kindArg = opt("--kind") ?? "short"
            let kind: BreakKind = kindArg == "short" ? .short : .long
            let hard = kindArg == "hard", used = args.contains("--used")
            var n = Int(opt("--from") ?? "30") ?? 30
            let hold = Int(opt("--hold") ?? "12") ?? 12
            if let l = opt("--lang"), let lang = AppLanguage(rawValue: l) { AppLanguage.override = lang }
            let screenArg = opt("--screen") ?? "pointer"
            setvbuf(stdout, nil, _IOLBF, 0)
            Task { @MainActor in
                #if DEBUG
                NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .mouseEntered, .mouseMoved]) { e in
                    print("event \(e.type.rawValue) in window level \(e.window?.level.rawValue ?? -1) key=\(e.window?.isKeyWindow ?? false) hit=\(e.window?.contentView?.hitTest(e.locationInWindow).map { String(describing: type(of: $0)) } ?? "-")"); return e
                }
                NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { e in print("global mouseDown at \(NSEvent.mouseLocation)") }
                let c = PreBreakController()
                c.screenOverride = {
                    switch screenArg {
                    case "builtin": return NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
                    case "external": return NSScreen.screens.first { $0.safeAreaInsets.top == 0 }
                    default: return nil
                    }
                }
                c.onStartNow = { print("tap: break now"); c.dismissAll() }
                c.onPostpone = { print("tap: snooze"); c.update(nil, removal: .animated) }
                c.onSkip = { print("tap: skip"); c.update(nil, removal: .animated) }
                c.onUrgent = { print("tap: urgent"); c.update(nil, removal: .immediate) }
                func st(_ n: Int) -> PreBreakState {
                    PreBreakState(kind: kind, secondsLeft: n, snooze: hard ? .hidden : (used ? .usedUp : .available(minutes: 5)),
                                  canSkip: kind == .short, atHardLine: hard, typingWait: false, showCard: true, showPill: n <= 10)
                }
                for i in 0..<hold {
                    c.update(st(max(1, n)), removal: .animated)
                    if i == 1 { print("shown, screen: \(screenArg)") }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    n -= 1
                }
                c.update(nil, removal: .animated)
                try? await Task.sleep(nanoseconds: 500_000_000)
                #endif
                exit(0)
            }
            app.run(); exit(0)
        }
        if args.contains("--debug-selftest-break-key") {
            // Visible: never run on a user's Mac without asking. Asserts the break window is key once it appears.
            Task { @MainActor in
                var ok = true
                overlay.showShort(duration: 2)
                try? await Task.sleep(nanoseconds: 300_000_000)
                let s = overlay.keyTargetForTest?.isKeyWindow == true
                print(s ? "ok   short break window is key" : "FAIL short break window is key"); ok = ok && s
                overlay.dismiss(animated: false)
                overlay.showLong(duration: 2, onSnooze: { _ in }, onSkip: {})
                try? await Task.sleep(nanoseconds: 500_000_000)
                let l = overlay.keyTargetForTest?.isKeyWindow == true && NSApp.keyWindow === overlay.keyTargetForTest
                print(l ? "ok   long break window is key" : "FAIL long break window is key"); ok = ok && l
                overlay.dismiss(animated: false)
                print(ok ? "BREAKKEY PASS" : "BREAKKEY FAIL"); exit(ok ? 0 : 1)
            }
            app.run(); exit(0)
        }
        if let i = args.firstIndex(of: "--debug-render"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                #if DEBUG
                BreakViewSnapshots.write(to: dir)
                #endif
                exit(0)
            }
            app.run()
            exit(0)
        }
        for flag in ["--debug-render-prebreak", "--debug-render-pill"] {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { continue }
            let dir = URL(fileURLWithPath: args[i + 1])
            MainActor.assumeIsolated {
                if flag == "--debug-render-prebreak" { PreBreakSnapshots.writePanels(to: dir) } else {
                    print("The pill is frosted glass, which ImageRenderer cannot draw. Run scripts/render-pill.sh <dir> instead (captures the real window).")
                    exit(2)
                }
            }
            exit(0)
        }
        if args.contains("--debug-selftest-prebreak") {
            let ok = MainActor.assumeIsolated { PreBreakSnapshots.selftest() }
            print(ok ? "PREBREAK PASS" : "PREBREAK FAIL"); exit(ok ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--debug-render-long"), i + 1 < args.count {
            if let j = args.firstIndex(of: "--oil"), j + 1 < args.count,
               let st = SceneryArt.OilStrength(rawValue: args[j + 1]) { SceneryArt.oilStrength = st }
            let dir = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                #if DEBUG
                BreakViewSnapshots.writeLong(to: dir, night: args.contains("--night"))
                #endif
                exit(0)
            }
            app.run()
            exit(0)
        }
        if args.contains("--debug-quotes-selftest") {
            // Picker rules with a throwaway defaults suite (never the user's).
            let d = UserDefaults(suiteName: "pausa.quotes.selftest")!
            d.removePersistentDomain(forName: "pausa.quotes.selftest")
            let day1 = Date(timeIntervalSince1970: 1_800_000_000), day2 = day1.addingTimeInterval(86_400)
            var ok = RestQuotes.all.count == 36 && BreakDaypart.allCases.allSatisfy { RestQuotes.pool($0).count == 12 }
            // Boundaries: 05:59 midnight, 06:00 day, 17:59 day, 18:00 night, 22:59 night, 23:00 midnight.
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
            func at(_ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: day1)! }
            let edges: [(Int, Int, BreakDaypart)] = [(5, 59, .midnight), (6, 0, .day), (17, 59, .day), (18, 0, .night),
                                                    (22, 59, .night), (23, 0, .midnight), (0, 0, .midnight)]
            ok = ok && edges.allSatisfy { BreakDaypart.current(at: at($0.0, $0.1), cal: cal) == $0.2 }
            let nightIDs = Set(RestQuotes.pool(.night).map(\.id))
            for _ in 0..<12 { _ = RestQuotes.next(.night, defaults: d, now: day1) }
            ok = ok && Set(d.stringArray(forKey: "restQuotes.used") ?? []) == nightIDs           // 12 picks, 12 distinct, night only
            let last = d.string(forKey: "restQuotes.last")
            _ = RestQuotes.next(.night, defaults: d, now: day1)                                   // pool exhausted → restart, not the last one
            ok = ok && d.string(forKey: "restQuotes.last") != last && nightIDs.contains(d.string(forKey: "restQuotes.last") ?? "")
            _ = RestQuotes.next(.midnight, defaults: d, now: day2)
            ok = ok && (d.stringArray(forKey: "restQuotes.used") ?? []).count == 1               // new day resets
            ok = ok && (d.string(forKey: "restQuotes.last") ?? "").hasPrefix("break.long.quote.midnight.")
            AppLanguage.override = .fr
            ok = ok && (RestQuotes.text(id: "break.long.quote.midnight.8") ?? "") == "C'est tout pour aujourd'hui. Bonne nuit."
            d.removePersistentDomain(forName: "pausa.quotes.selftest")
            print(ok ? "QUOTES PASS (all=\(RestQuotes.all.count), 12 per daypart)" : "QUOTES FAIL"); exit(ok ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--debug-render-quotes"), i + 1 < args.count {
            // --debug-render-quotes <dir> --lang <code>: quote under the countdown, short + long.
            if let j = args.firstIndex(of: "--lang"), j + 1 < args.count { AppLanguage.override = AppLanguage(rawValue: args[j + 1]) }
            let dir = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                #if DEBUG
                BreakViewSnapshots.writeQuotes(to: dir, lang: AppLanguage.current.rawValue)
                #endif
                exit(0)
            }
            app.run()
            exit(0)
        }
        if let i = args.firstIndex(of: "--debug-render-short"), i + 1 < args.count {
            let out = URL(fileURLWithPath: args[i + 1])
            let sample = (i + 2 < args.count && !args[i + 2].hasPrefix("--")) ? NSImage(contentsOfFile: args[i + 2]) : nil
            Task { @MainActor in
                #if DEBUG
                BreakViewSnapshots.writeShortBlur(to: out, sample: sample, opacity: num(after: "--opacity", 1))
                #endif
                exit(0)
            }
            app.run()
            exit(0)
        }
        if args.contains("--debug-detect") {
            let secs = num(after: "--debug-detect", 10)
            print("== audio input devices ==")
            AudioInputMonitor.inputDevices().forEach { print("  \($0)") }
            print("== cameras ==")
            CameraMonitor.cameras().forEach { print("  \($0)") }
            if let f = FullscreenMonitor.frontmostCoversDisplay() {
                print("== frontmost == \(f.app) coversDisplay=\(f.covers) allowlisted=\(f.allowlisted)")
            }
            detector.onAway = { print("away: \($0)") }
            let sub = detector.$reasons.sink { r in
                print("[\(Date())] reasons=\(r.isEmpty ? "[]" : r.map(\.description).sorted().joined(separator: ","))")
            }
            keep.append(sub as AnyObject)
            detector.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
        } else if args.contains("--debug-about") {
            MainActor.assumeIsolated { MenuBarController.showAbout() }
            DispatchQueue.main.asyncAfter(deadline: .now() + num(after: "--debug-about", 8)) { exit(0) }
        } else if args.contains("--debug-short") {
            let secs = num(after: "--debug-short", 5)
            overlay.showShort(duration: secs,
                              onSkip: { print("short: skipped"); exit(0) },
                              onFinish: { print("short: finished"); exit(0) })
        } else if args.contains("--debug-long") {
            let secs = num(after: "--debug-long", 8)
            overlay.showLong(duration: secs,
                             onSnooze: { m in print("long: snooze \(m)"); exit(0) },
                             onSkip: { print("long: skip"); exit(0) },
                             onFinish: { print("long: finished"); DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { exit(0) } })
        }
        // hard safety stop so nothing lingers on Bowen's Mac
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(0) }
        app.run()
        exit(0)
    }
}
#endif
