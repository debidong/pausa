import Darwin
import AppKit

/// Maps helper processes (Chrome "Helper (GPU)", Safari com.apple.WebKit.GPU/WebContent, Arc,
/// Edge, Firefox "plugin-container"/media) back to the app the user sees. Zero permission.
enum ProcessLineage {
    private typealias RespFn = @convention(c) (pid_t) -> pid_t
    /// responsibility_get_pid_responsible_for_pid is libSystem SPI; resolved at runtime so a
    /// missing symbol just falls back to the parent chain.
    private static let responsible: RespFn? = {
        guard let h = dlopen(nil, RTLD_NOW),
              let sym = dlsym(h, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: RespFn.self)
    }()

    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let pp = info.kp_eproc.e_ppid
        return pp > 1 ? pp : nil
    }

    static func path(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// Candidate owner pids: self, the "responsible" pid, then up the parent chain.
    static func lineage(of pid: pid_t) -> [pid_t] {
        var out = [pid]
        if let r = responsible?(pid), r > 0, r != pid { out.append(r) }
        var p = pid
        for _ in 0..<8 { guard let pp = parent(of: p) else { break }; out.append(pp); p = pp }
        return out
    }

    /// The .app bundle path containing `path` (outermost "X.app" wins, so
    /// ".../Google Chrome.app/.../Google Chrome Helper (GPU).app/..." maps to Chrome).
    static func outerAppBundle(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") ?? path.range(of: ".app", options: .backwards) else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }
}
