#if DEBUG
import AppKit

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
                var (w, tabs) = SettingsTabsController.makeWindow(settings: .shared, onPreview: {}, autosave: key)
                let want = SettingsTabsController.initialSize(for: w.screen ?? NSScreen.main)
                check("first open \(want) (\(w.frame.size))", w.frame.size == want)
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
                w.setFrame(NSRect(origin: w.frame.origin, size: NSSize(width: 900, height: 600)), display: false)
                for p in [SettingsPage.about, .general, .breaks] {
                    tabs.select(p)
                    check("\(p.rawValue) keeps 900x600 (\(w.frame.size))", w.frame.size == NSSize(width: 900, height: 600))
                    let f = fixedSizeConstraints()
                    check("\(p.rawValue) drag not blocked \(f)", f.isEmpty)
                }
                check("min frame after switches (\(SettingsTabsController.minimumFrame(w)))", SettingsTabsController.minimumFrame(w) == NSSize(width: 500, height: 420))
                w.saveFrame(usingName: key)   // what AppKit's autosave does on close/quit
                w.close()
                (w, tabs) = SettingsTabsController.makeWindow(settings: .shared, onPreview: {}, autosave: key)
                check("reopen 900x600 (\(w.frame.size))", w.frame.size == NSSize(width: 900, height: 600))
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
            let shortIDs = Set(RestQuotes.pool(.short).map(\.id)), n = shortIDs.count
            let day1 = Date(timeIntervalSince1970: 1_800_000_000), day2 = day1.addingTimeInterval(86_400)
            var ok = RestQuotes.all.count == 108 && n == 22 && RestQuotes.pool(.short).allSatisfy { !$0.longOnly }
            for _ in 0..<n { _ = RestQuotes.next(.short, defaults: d, now: day1) }
            ok = ok && Set(d.stringArray(forKey: "restQuotes.used") ?? []) == shortIDs          // n picks, n distinct, all short pool
            let last = d.string(forKey: "restQuotes.last")
            _ = RestQuotes.next(.short, defaults: d, now: day1)                                   // pool exhausted → restart, not the last one
            ok = ok && d.string(forKey: "restQuotes.last") != last
            for _ in 0..<70 { _ = RestQuotes.next(.long, defaults: d, now: day1) }
            ok = ok && Set(d.stringArray(forKey: "restQuotes.used") ?? []).count >= 71            // long picks don't repeat
            _ = RestQuotes.next(.long, defaults: d, now: day2)
            ok = ok && (d.stringArray(forKey: "restQuotes.used") ?? []).count == 1               // new day resets
            AppLanguage.override = .fr
            let fr = RestQuotes.text(id: "rest.001") ?? ""
            ok = ok && fr.hasPrefix("Tes yeux")
            d.removePersistentDomain(forName: "pausa.quotes.selftest")
            print(ok ? "QUOTES PASS (pool short=\(n), all=\(RestQuotes.all.count))" : "QUOTES FAIL"); exit(ok ? 0 : 1)
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
