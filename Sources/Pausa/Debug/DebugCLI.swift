import AppKit

/// Debug entry points for Detection/ and Overlay/ (no app shell needed).
///   --debug-detect [seconds]        print detector state every second (default 10s)
///   --debug-short [seconds]         show the short break (default 5s), then exit
///   --debug-long [seconds]          show the long break (default 8s), then exit
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
        } else if args.contains("--debug-short") {
            let secs = num(after: "--debug-short", 5)
            overlay.showShort(duration: secs) { print("short: finished"); exit(0) }
        } else if args.contains("--debug-long") {
            let secs = num(after: "--debug-long", 8)
            overlay.showLong(duration: secs,
                             onSnooze: { print("long: snooze"); exit(0) },
                             onSkip: { print("long: skip"); exit(0) },
                             onFinish: { print("long: finished"); DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { exit(0) } })
        }
        // hard safety stop so nothing lingers on Bowen's Mac
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(0) }
        app.run()
        exit(0)
    }
}
