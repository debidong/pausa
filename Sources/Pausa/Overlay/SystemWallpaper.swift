import AVFoundation
import AppKit
import CoreGraphics
import ImageIO
import PausaCore
import SwiftUI
import os

/// 系统壁纸: mirrors the user's macOS desktop wallpaper or Aerial screensaver on long breaks.
///
/// Design invariants:
/// 1. Never trigger an unexpected macOS TCC folder dialog on first launch or during an automatic break:
///    sensitive paths (`Desktop`, `Documents`, `Downloads`, iCloud Drive, `/Volumes`) are detected by
///    pure lexical path-prefix rules before touching the filesystem. Fresh installs or un-authorized
///    wallpaper changes silently fall back to `.random` until the user explicitly picks `系统壁纸`.
/// 2. Apple Aerial `.mov` wallpapers/screensavers play muted with `preventsDisplaySleepDuringVideoPlayback = false`
///    (Plan B), falling back to a still frame under Reduce Motion, and tearing down the decoder as soon
///    as the break window closes.
/// 3. Procedural wallpapers (Solid Color, Macintosh, Hello) or cloud assets not yet downloaded fall back
///    per-screen to `.softDesktop` (blurred live desktop) for that break.
enum SystemWallpaper {
    private static let log = Logger(subsystem: "app.pausa", category: "system-wallpaper")

    // MARK: - TCC & Sandbox Classification (pure lexical string operations, zero syscalls)

    enum TCCBucket: String, CaseIterable, Sendable, Equatable {
        case desktop
        case documents
        case downloads
        case icloud
        case externalVolume
    }

    /// Pure lexical path normalization (`//`, `.`, `..`, trailing `/`) without calling `stat` or `readlink`.
    static func lexicalNormalize(_ rawPath: String, home: String? = nil) -> String {
        var expanded = rawPath
        if expanded == "~", let home {
            expanded = home
        } else if expanded.hasPrefix("~/"), let home {
            expanded = home + String(expanded.dropFirst(1))
        }
        let isAbsolute = expanded.hasPrefix("/")
        var stack: [Substring] = []
        for part in expanded.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !stack.isEmpty && stack.last != ".." {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append(part)
                }
            } else {
                stack.append(part)
            }
        }
        let joined = stack.joined(separator: "/")
        if isAbsolute { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }

    /// True when the wallpaper lives inside Photos.app's package or macOS's private wallpaper container,
    /// where standard Files & Folders TCC permission still cannot grant read access.
    static func isPhotosOrContainerIsolated(path rawPath: String, home rawHome: String) -> Bool {
        let home = lexicalNormalize(rawHome)
        let path = lexicalNormalize(rawPath, home: home)
        if path.contains(".photoslibrary/") || path.hasSuffix(".photoslibrary") { return true }
        let containerPrefixes = [
            "\(home)/Library/Containers/com.apple.wallpaper",
            "\(home)/Library/Containers/com.apple.Photos",
            "\(home)/Library/Group Containers/group.com.apple.Photos"
        ]
        return containerPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") || path.hasPrefix($0 + ".") }
    }

    /// Returns the macOS TCC folder bucket that protects `rawPath`, or `nil` when readable without TCC.
    static func tccBucket(forPath rawPath: String, home rawHome: String) -> TCCBucket? {
        let home = lexicalNormalize(rawHome)
        let path = lexicalNormalize(rawPath, home: home)
        func under(_ dir: String) -> Bool { path == dir || path.hasPrefix(dir + "/") }
        if under("\(home)/Desktop") { return .desktop }
        if under("\(home)/Documents") { return .documents }
        if under("\(home)/Downloads") { return .downloads }
        if under("\(home)/Library/Mobile Documents") { return .icloud }
        if path.hasPrefix("/Volumes/") && path != "/Volumes" { return .externalVolume }
        return nil
    }

    // MARK: - Index.plist & Wallpaper Candidate Resolution

    enum WallpaperCandidate: Equatable, Sendable {
        case aerial(assetID: String?)
        case file(String)
        case photosIsolated
        case procedural
    }

    enum AccessResult: Equatable, Sendable {
        case readable
        case permissionDenied
        case missingOrInvalid
    }

    struct ScreenInfo: Sendable {
        var id: CGDirectDisplayID
        var uuid: String?
        var desktopImagePath: String?
    }

    struct EnvironmentProbe {
        var homeDirectory: String
        var loadIndexPlist: () -> [String: Any]?
        var screens: () -> [ScreenInfo]
        var aerialSearchDirs: [String]
        var checkReadable: (String) -> AccessResult
        var onAlert: ((AlertKind) -> Void)?

        enum AlertKind: Equatable {
            case permissionNeeded
            case photosIsolated
        }

        static var live: EnvironmentProbe {
            let home = lexicalNormalize(NSHomeDirectory())
            return EnvironmentProbe(
                homeDirectory: home,
                loadIndexPlist: {
                    let plistPath = "\(home)/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
                          let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
                    else { return nil }
                    return obj
                },
                screens: {
                    NSScreen.screens.map { s in
                        let id = displayID(for: s) ?? 0
                        let uuid = id != 0 ? displayUUID(for: id) : nil
                        let desktopPath = NSWorkspace.shared.desktopImageURL(for: s)?.path
                        return ScreenInfo(id: id, uuid: uuid, desktopImagePath: desktopPath)
                    }
                },
                aerialSearchDirs: [
                    "\(home)/Library/Application Support/com.apple.wallpaper/aerials/videos",
                    "/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS",
                    "/System/Library/Desktop Pictures/.wallpapers"
                ],
                checkReadable: { path in liveCheckReadable(path: path) },
                onAlert: nil
            )
        }
    }

    /// Test seam: overrides filesystem/screen queries without touching the host's real desktop or TCC.
    static var probeOverride: EnvironmentProbe?
    private static var activeProbe: EnvironmentProbe { probeOverride ?? .live }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func displayUUID(for id: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cfUUID) as String?
    }

    /// Decodes a file path from Swift `PropertyListEncoder` URL dictionaries (`{"relative": ..., "base": ...}`),
    /// raw `file://` URL strings, `URL` values, or plain POSIX paths without touching the filesystem.
    static func decodePlistFilePath(_ any: Any, home: String? = nil) -> String? {
        if let url = any as? URL {
            return url.isFileURL ? lexicalNormalize(url.path, home: home) : nil
        }
        if let str = any as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("file://"), let u = URL(string: trimmed), u.isFileURL {
                return lexicalNormalize(u.path, home: home)
            }
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
                return lexicalNormalize(trimmed, home: home)
            }
            return nil
        }
        if let dict = any as? [String: Any], let rel = dict["relative"] as? String {
            if let baseObj = dict["base"], let basePath = decodePlistFilePath(baseObj, home: home) {
                let baseURL = URL(fileURLWithPath: basePath, isDirectory: true)
                if let resolved = URL(string: rel, relativeTo: baseURL), resolved.isFileURL {
                    return lexicalNormalize(resolved.path, home: home)
                }
                let unescaped = rel.removingPercentEncoding ?? rel
                return lexicalNormalize(basePath + "/" + unescaped, home: home)
            }
            if rel.hasPrefix("file://"), let u = URL(string: rel), u.isFileURL {
                return lexicalNormalize(u.path, home: home)
            }
            if rel.hasPrefix("/") || rel.hasPrefix("~/") {
                return lexicalNormalize(rel, home: home)
            }
        }
        return nil
    }

    private static func isSentinelDefaultDesktop(_ path: String) -> Bool {
        lexicalNormalize(path) == "/System/Library/CoreServices/DefaultDesktop.heic"
    }

    /// Resolves a single screen's wallpaper candidate from macOS's `Index.plist` + `desktopImageURL` fallback.
    static func resolveCandidate(indexPlist: [String: Any]?,
                                 displayUUID: String?,
                                 desktopImagePath: String?,
                                 home: String) -> WallpaperCandidate {
        if let plist = indexPlist {
            var nodes: [[String: Any]] = []
            if let uuid = displayUUID?.uppercased(),
               let displays = plist["Displays"] as? [String: Any],
               let matched = displays.first(where: { $0.key.uppercased() == uuid })?.value as? [String: Any] {
                nodes.append(matched)
            }
            if let spaces = plist["Spaces"] as? [String: Any] {
                for (_, val) in spaces {
                    guard let spaceDict = val as? [String: Any] else { continue }
                    if let uuid = displayUUID?.uppercased(),
                       let spaceDisplays = spaceDict["Displays"] as? [String: Any],
                       let matched = spaceDisplays.first(where: { $0.key.uppercased() == uuid })?.value as? [String: Any] {
                        nodes.append(matched)
                    } else if let def = spaceDict["Default"] as? [String: Any] {
                        nodes.append(def)
                    }
                }
            }
            if let all = plist["AllSpacesAndDisplays"] as? [String: Any] { nodes.append(all) }
            if let sys = plist["SystemDefault"] as? [String: Any] { nodes.append(sys) }

            var sawProcedural = false
            for node in nodes {
                for channel in ["Desktop", "Linked", "Idle"] {
                    guard let channelDict = node[channel] as? [String: Any],
                          let content = channelDict["Content"] as? [String: Any],
                          let choices = content["Choices"] as? [[String: Any]]
                    else { continue }
                    for choice in choices {
                        if let candidate = parseChoice(choice, desktopImagePath: desktopImagePath, home: home) {
                            if candidate == .procedural {
                                sawProcedural = true
                                continue   // e.g. solid-color desktop + Aerial screensaver in Idle
                            }
                            return candidate
                        }
                    }
                }
                if sawProcedural { return .procedural }
            }

            if let dp = desktopImagePath, !isSentinelDefaultDesktop(dp) {
                return isPhotosOrContainerIsolated(path: dp, home: home)
                    ? .photosIsolated
                    : .file(lexicalNormalize(dp, home: home))
            }
            return .procedural
        }

        // macOS 13 Ventura (or missing Index.plist): NSWorkspace.desktopImageURL is the source of truth.
        if let dp = desktopImagePath {
            return isPhotosOrContainerIsolated(path: dp, home: home)
                ? .photosIsolated
                : .file(lexicalNormalize(dp, home: home))
        }
        return .procedural
    }

    private static func parseChoice(_ choice: [String: Any],
                                    desktopImagePath: String?,
                                    home: String) -> WallpaperCandidate? {
        let provider = (choice["Provider"] as? String) ?? ""
        let config: [String: Any]? = {
            guard let data = choice["Configuration"] as? Data, !data.isEmpty else { return nil }
            return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        }()

        var paths: [String] = []
        if let files = choice["Files"] as? [Any] {
            paths.append(contentsOf: files.compactMap { decodePlistFilePath($0, home: home) })
        }
        if let config {
            for key in ["url", "imageFileURL", "folderURL", "fileURL", "module"] {
                if let val = config[key], let p = decodePlistFilePath(val, home: home) {
                    paths.append(p)
                }
            }
        }

        if provider.localizedCaseInsensitiveContains("photos") ||
            paths.contains(where: { isPhotosOrContainerIsolated(path: $0, home: home) }) {
            return .photosIsolated
        }

        if provider == "com.apple.wallpaper.choice.aerials" || config?["assetID"] is String {
            let rawID = (config?["assetID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .aerial(assetID: (rawID?.isEmpty == false) ? rawID : nil)
        }

        if let first = paths.first {
            return .file(first)
        }

        if provider.contains(".image") || provider.contains(".dynamic") || provider.contains(".macOS") {
            if let dp = desktopImagePath, !isSentinelDefaultDesktop(dp) {
                return isPhotosOrContainerIsolated(path: dp, home: home)
                    ? .photosIsolated
                    : .file(lexicalNormalize(dp, home: home))
            }
        }

        if !provider.isEmpty {
            return .procedural
        }
        return nil
    }

    // MARK: - Authorization & Fresh-Install Safety

    static func authorizedBuckets(in ud: UserDefaults = PausaDefaults.store) -> Set<TCCBucket> {
        let raw = ud.stringArray(forKey: DefaultsKey.systemWallpaperAuthorizedBuckets) ?? []
        return Set(raw.compactMap(TCCBucket.init(rawValue:)))
    }

    static func setAuthorizedBuckets(_ buckets: Set<TCCBucket>, in ud: UserDefaults = PausaDefaults.store) {
        ud.set(buckets.map(\.rawValue).sorted(), forKey: DefaultsKey.systemWallpaperAuthorizedBuckets)
    }

    /// Candidate restriction before touching any protected path.
    enum PolicyStatus: Equatable {
        case ready
        case needsTCC(TCCBucket, path: String)
        case photosIsolated
    }

    static func evaluatePolicy(for candidate: WallpaperCandidate,
                               home: String,
                               authorized: Set<TCCBucket>) -> PolicyStatus {
        switch candidate {
        case .aerial, .procedural:
            return .ready
        case .photosIsolated:
            return .photosIsolated
        case .file(let path):
            if isPhotosOrContainerIsolated(path: path, home: home) {
                return .photosIsolated
            }
            if let bucket = tccBucket(forPath: path, home: home), !authorized.contains(bucket) {
                return .needsTCC(bucket, path: path)
            }
            return .ready
        }
    }

    private static func currentCandidates(probe: EnvironmentProbe) -> [(screenID: CGDirectDisplayID, candidate: WallpaperCandidate)] {
        let plist = probe.loadIndexPlist()
        let screens = probe.screens()
        if screens.isEmpty {
            return [(0, resolveCandidate(indexPlist: plist, displayUUID: nil, desktopImagePath: nil, home: probe.homeDirectory))]
        }
        return screens.map { s in
            (s.id, resolveCandidate(indexPlist: plist, displayUUID: s.uuid, desktopImagePath: s.desktopImagePath, home: probe.homeDirectory))
        }
    }

    /// True when `.systemWallpaper` can be used right now without risking an unprompted TCC popup
    /// or hitting a sandboxed Photos wallpaper.
    static func canDefaultWithoutPermissionPrompt(defaults ud: UserDefaults = PausaDefaults.store) -> Bool {
        let probe = activeProbe
        let auth = authorizedBuckets(in: ud)
        let list = currentCandidates(probe: probe)
        return list.contains { evaluatePolicy(for: $0.candidate, home: probe.homeDirectory, authorized: auth) == .ready } &&
               !list.contains {
                   if case .needsTCC = evaluatePolicy(for: $0.candidate, home: probe.homeDirectory, authorized: auth) { return true }
                   return false
               }
    }

    private static func liveCheckReadable(path: String) -> AccessResult {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            do {
                _ = try fm.contentsOfDirectory(atPath: path)
                return .readable
            } catch {
                return isPermissionError(error) ? .permissionDenied : .missingOrInvalid
            }
        }
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            try? handle.close()
            return .readable
        } catch {
            return isPermissionError(error) ? .permissionDenied : .missingOrInvalid
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EACCES) || ns.code == Int(EPERM)) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }

    /// Explicit user action in `Settings › General › Theme`: verifies access (triggering macOS's native
    /// folder permission prompt when needed) or explains why access failed.
    @MainActor static func selectFromMenu(in window: NSWindow?,
                                          settings: Settings = .shared,
                                          defaults ud: UserDefaults? = nil,
                                          completion: (() -> Void)? = nil) {
        let store = ud ?? PausaDefaults.store
        let probe = activeProbe
        let items = currentCandidates(probe: probe)

        // Pure Photos-isolated setup on all displays: explain immediately without changing the theme.
        if !items.isEmpty && items.allSatisfy({ $0.candidate == .photosIsolated }) {
            showPhotosIsolatedAlert(in: window, probe: probe)
            completion?()
            return
        }

        let fileTargets: [(path: String, bucket: TCCBucket?)] = items.compactMap { _, cand in
            guard case .file(let p) = cand else { return nil }
            if isPhotosOrContainerIsolated(path: p, home: probe.homeDirectory) { return nil }
            return (p, tccBucket(forPath: p, home: probe.homeDirectory))
        }

        // Fast path: Aerials / procedural / non-TCC system files with no TCC bucket to prompt.
        if fileTargets.isEmpty {
            settings.theme = .systemWallpaper
            prewarmInBackground()
            completion?()
            return
        }

        // In deterministic unit tests (`probeOverride != nil`), run synchronously on MainActor;
        // in live app usage, run file open off the main thread so a TCC prompt never blocks UI.
        if probeOverride != nil {
            var granted = Set<TCCBucket>()
            var denied = false
            for target in fileTargets {
                switch probe.checkReadable(target.path) {
                case .readable, .missingOrInvalid:
                    if let b = target.bucket { granted.insert(b) }
                case .permissionDenied:
                    denied = true
                }
                if denied { break }
            }
            finishMenuSelection(result: (denied, granted), in: window, settings: settings, store: store, probe: probe)
            completion?()
        } else {
            Task { @MainActor in
                let result: (denied: Bool, grantedBuckets: Set<TCCBucket>) = await Task.detached(priority: .userInitiated) {
                    var granted = Set<TCCBucket>()
                    for target in fileTargets {
                        switch Self.liveCheckReadable(path: target.path) {
                        case .readable, .missingOrInvalid:
                            if let b = target.bucket { granted.insert(b) }
                        case .permissionDenied:
                            return (true, granted)
                        }
                    }
                    return (false, granted)
                }.value
                finishMenuSelection(result: result, in: window, settings: settings, store: store, probe: probe)
                completion?()
            }
        }
    }

    @MainActor private static func finishMenuSelection(result: (denied: Bool, grantedBuckets: Set<TCCBucket>),
                                                       in window: NSWindow?,
                                                       settings: Settings,
                                                       store: UserDefaults,
                                                       probe: EnvironmentProbe) {
        var auth = authorizedBuckets(in: store)
        auth.formUnion(result.grantedBuckets)
        setAuthorizedBuckets(auth, in: store)
        if result.denied {
            showPermissionAlert(in: window, probe: probe)
        } else {
            settings.theme = .systemWallpaper
            prewarmInBackground()
        }
    }

    @MainActor private static func showPermissionAlert(in window: NSWindow?, probe: EnvironmentProbe) {
        if let hook = probe.onAlert { hook(.permissionNeeded); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("systemWallpaper.permission.title")
        alert.informativeText = L("systemWallpaper.permission.body")
        alert.addButton(withTitle: L("systemWallpaper.openPrivacy"))
        alert.addButton(withTitle: L("common.ok"))
        let handle: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .alertFirstButtonReturn,
                  let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
            else { return }
            NSWorkspace.shared.open(url)
        }
        if let window, window.isVisible { alert.beginSheetModal(for: window, completionHandler: handle) }
        else { handle(alert.runModal()) }
    }

    @MainActor private static func showPhotosIsolatedAlert(in window: NSWindow?, probe: EnvironmentProbe) {
        if let hook = probe.onAlert { hook(.photosIsolated); return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("systemWallpaper.photos.title")
        alert.informativeText = L("systemWallpaper.photos.body")
        alert.addButton(withTitle: L("common.ok"))
        if let window, window.isVisible { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }

    // MARK: - Media Decoding, Contrast Caching & Break Preparation

    enum ScreenBackdrop {
        case video(url: URL, poster: CGImage?, extraDim: Double)
        case image(image: CGImage, extraDim: Double)
        case softDesktop
    }

    private static let cacheLock = NSLock()
    private static var videoMetaCache: [String: (poster: CGImage?, extraDim: Double)] = [:]
    private static var imageDecodeCache: [String: (image: CGImage, extraDim: Double)] = [:]
    private static var activeBackdrops: [CGDirectDisplayID: ScreenBackdrop] = [:]
    private static var defaultBackdrop: ScreenBackdrop = .softDesktop

    /// Warms video poster + contrast caches off the main thread so the first break opens in 0 ms.
    static func prewarmInBackground() {
        guard probeOverride == nil, !Settings.dryRun else { return }
        let probe = activeProbe
        let auth = authorizedBuckets()
        let items = currentCandidates(probe: probe)
        let aspect: Double = Thread.isMainThread
            ? MainActor.assumeIsolated { PhotoImport.referenceAspect }
            : 16.0 / 10.0
        DispatchQueue.global(qos: .utility).async {
            for (_, cand) in items {
                guard evaluatePolicy(for: cand, home: probe.homeDirectory, authorized: auth) == .ready else { continue }
                _ = resolveBackdrop(for: cand, seed: 1, night: false, px: 1920, aspect: aspect, probe: probe)
            }
        }
    }

    /// Called when a long break (or 5 s preview) starts. Resolves per-screen backdrops, or switches
    /// back to `.random` without touching disk if the user moved their wallpaper into an un-authorized TCC folder.
    static func prepare(long: Bool,
                        seed: UInt64 = 1,
                        night: Bool = false,
                        settings: Settings = .shared,
                        defaults ud: UserDefaults? = nil) {
        activeBackdrops.removeAll()
        defaultBackdrop = .softDesktop
        guard long, settings.theme == .systemWallpaper else { return }

        let store = ud ?? PausaDefaults.store
        let probe = activeProbe
        var auth = authorizedBuckets(in: store)
        let items = currentCandidates(probe: probe)

        // Guard against surprise TCC popups if the user switched wallpaper to ~/Desktop etc. after install.
        let hasUnauthorizedTCC = items.contains {
            if case .needsTCC = evaluatePolicy(for: $0.candidate, home: probe.homeDirectory, authorized: auth) { return true }
            return false
        }
        let allPhotosIsolated = !items.isEmpty && items.allSatisfy {
            evaluatePolicy(for: $0.candidate, home: probe.homeDirectory, authorized: auth) == .photosIsolated
        }
        if hasUnauthorizedTCC || allPhotosIsolated {
            log.notice("system wallpaper requires explicit permission or Photos access; switching default to random")
            settings.theme = .random
            return
        }

        let px = SceneryArt.override ?? SceneryArt.targetPixels
        let aspect: Double = Thread.isMainThread
            ? MainActor.assumeIsolated { PhotoImport.referenceAspect }
            : 16.0 / 10.0
        var revokedAny = false

        for (sid, cand) in items {
            if case .file(let path) = cand, let bucket = tccBucket(forPath: path, home: probe.homeDirectory) {
                if probe.checkReadable(path) == .permissionDenied {
                    auth.remove(bucket)
                    revokedAny = true
                    continue
                }
            }
            let resolved = resolveBackdrop(for: cand, seed: seed, night: night, px: px, aspect: aspect, probe: probe)
            activeBackdrops[sid] = resolved
            if defaultBackdropIsSoftDesktop, case .softDesktop = resolved {} else if defaultBackdropIsSoftDesktop {
                defaultBackdrop = resolved
            }
        }

        if revokedAny {
            setAuthorizedBuckets(auth, in: store)
            if activeBackdrops.isEmpty {
                settings.theme = .random
                return
            }
        }
        if let first = items.first, let b = activeBackdrops[first.screenID] {
            defaultBackdrop = b
        }
    }

    private static var defaultBackdropIsSoftDesktop: Bool {
        if case .softDesktop = defaultBackdrop { return true }
        return false
    }

    static func backdrop(for screenID: CGDirectDisplayID?) -> ScreenBackdrop {
        if let sid = screenID, let found = activeBackdrops[sid] { return found }
        return defaultBackdrop
    }

    static func usesSoftDesktopTint(for screenID: CGDirectDisplayID?, animate: Bool) -> Bool {
        switch backdrop(for: screenID) {
        case .softDesktop:
            return true
        case .video(_, let poster, _):
            return !animate && poster == nil
        case .image:
            return false
        }
    }

    // MARK: - Candidate -> ScreenBackdrop Resolution

    static func resolveBackdrop(for candidate: WallpaperCandidate,
                                seed: UInt64,
                                night: Bool,
                                px: Int,
                                aspect: Double,
                                probe: EnvironmentProbe) -> ScreenBackdrop {
        switch candidate {
        case .procedural, .photosIsolated:
            return .softDesktop
        case .aerial(let assetID):
            if let movURL = findAerialVideo(assetID: assetID, seed: seed, dirs: probe.aerialSearchDirs) {
                return buildVideoBackdrop(url: movURL, aspect: aspect)
            }
            if let id = assetID,
               let thumbURL = findAerialThumbnail(assetID: id, home: probe.homeDirectory),
               let img = decodeImageAndContrast(url: thumbURL, night: night, px: px, aspect: aspect, requireMinSide: 1000) {
                return .image(image: img.image, extraDim: img.extraDim)
            }
            return .softDesktop
        case .file(let rawPath):
            return resolveFileBackdrop(path: rawPath, seed: seed, night: night, px: px, aspect: aspect)
        }
    }

    static func findAerialVideo(assetID: String?, seed: UInt64, dirs: [String]) -> URL? {
        let fm = FileManager.default
        if let id = assetID {
            for dir in dirs {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent("\(id).mov")
                if let size = (try? fm.attributesOfItem(atPath: candidate.path))?[.size] as? NSNumber, size.int64Value > 0 {
                    return candidate
                }
            }
            return nil
        }
        // Shuffle Aerials (`assetID == nil`): pick deterministically among downloaded `.mov` files.
        var available: [URL] = []
        for dir in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names.sorted() where n.lowercased().hasSuffix(".mov") {
                let u = URL(fileURLWithPath: dir).appendingPathComponent(n)
                if let size = (try? fm.attributesOfItem(atPath: u.path))?[.size] as? NSNumber, size.int64Value > 0 {
                    available.append(u)
                }
            }
        }
        guard !available.isEmpty else { return nil }
        return available[Int(seed % UInt64(available.count))]
    }

    private static func findAerialThumbnail(assetID: String, home: String) -> URL? {
        let dir = "\(home)/Library/Application Support/com.apple.wallpaper/aerials/thumbnails"
        for ext in ["heic", "png", "jpg", "jpeg"] {
            let u = URL(fileURLWithPath: dir).appendingPathComponent("\(assetID).\(ext)")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    private static func resolveFileBackdrop(path: String,
                                            seed: UInt64,
                                            night: Bool,
                                            px: Int,
                                            aspect: Double) -> ScreenBackdrop {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return .softDesktop }

        if isDir.boolValue {
            let imageExts: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "webp", "tif", "tiff", "bmp", "mov"]
            guard let items = try? fm.contentsOfDirectory(atPath: path) else { return .softDesktop }
            let media = items.sorted().filter { name in
                !name.hasPrefix(".") && imageExts.contains((name as NSString).pathExtension.lowercased())
            }
            guard !media.isEmpty else { return .softDesktop }
            let chosen = URL(fileURLWithPath: path).appendingPathComponent(media[Int(seed % UInt64(media.count))]).path
            return resolveFileBackdrop(path: chosen, seed: seed, night: night, px: px, aspect: aspect)
        }

        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()

        if ext == "mov" {
            return buildVideoBackdrop(url: url, aspect: aspect)
        }

        if ext == "madesktop" {
            if let resolved = resolveMADesktopAsset(plistURL: url),
               let decoded = decodeImageAndContrast(url: resolved, night: night, px: px, aspect: aspect) {
                return .image(image: decoded.image, extraDim: decoded.extraDim)
            }
            return .softDesktop
        }

        if let decoded = decodeImageAndContrast(url: url, night: night, px: px, aspect: aspect) {
            return .image(image: decoded.image, extraDim: decoded.extraDim)
        }
        return .softDesktop
    }

    private static func resolveMADesktopAsset(plistURL: URL) -> URL? {
        guard let data = try? Data(contentsOf: plistURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let assetID = dict["mobileAssetID"] as? String
        else { return nil }
        let root = "/System/Library/AssetsV2/com_apple_MobileAsset_DesktopPicture"
        guard let bundles = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        for b in bundles where b.hasSuffix(".asset") {
            let candidate = URL(fileURLWithPath: root).appendingPathComponent(b).appendingPathComponent("AssetData/\(assetID).heic")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func buildVideoBackdrop(url: URL, aspect: Double) -> ScreenBackdrop {
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let key = "\(url.path)|\(mtime)"
        cacheLock.lock()
        if let hit = videoMetaCache[key] {
            cacheLock.unlock()
            return .video(url: url, poster: hit.poster, extraDim: hit.extraDim)
        }
        cacheLock.unlock()

        let poster = extractVideoKeyframe(url: url, maxPixelSize: 960)
        let dim = poster.map { measureExtraDim(image: $0, aspect: aspect) } ?? 0.22

        cacheLock.lock()
        if videoMetaCache.count > 8 { videoMetaCache.removeAll() }
        videoMetaCache[key] = (poster, dim)
        cacheLock.unlock()
        return .video(url: url, poster: poster, extraDim: dim)
    }

    static func extractVideoKeyframe(url: URL, maxPixelSize: Int) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity

        let box = LockedImageBox()
        let sem = DispatchSemaphore(value: 0)
        gen.generateCGImageAsynchronously(for: .zero) { image, _, _ in
            box.store(image)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 1.2)
        return box.load()
    }

    private final class LockedImageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var image: CGImage?
        func store(_ img: CGImage?) { lock.lock(); image = img; lock.unlock() }
        func load() -> CGImage? { lock.lock(); defer { lock.unlock() }; return image }
    }

    static func decodeImageAndContrast(url: URL,
                                       night: Bool,
                                       px: Int,
                                       aspect: Double,
                                       requireMinSide: Int = 0) -> (image: CGImage, extraDim: Double)? {
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let key = "\(url.path)|\(mtime)|\(night)|\(px)"
        cacheLock.lock()
        if let hit = imageDecodeCache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(src) == .statusComplete,
              CGImageSourceGetCount(src) >= 1
        else { return nil }

        let index = pickFrameIndex(source: src, night: night)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: px,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary) else { return nil }
        if requireMinSide > 0 && max(img.width, img.height) < requireMinSide { return nil }
        let dim = measureExtraDim(image: img, aspect: aspect)

        cacheLock.lock()
        if imageDecodeCache.count > 6 { imageDecodeCache.removeAll() }
        imageDecodeCache[key] = (img, dim)
        cacheLock.unlock()
        return (img, dim)
    }

    /// Selects the light vs dark frame of an Apple dynamic multi-frame `.heic` wallpaper (`apple_desktop:apr` / `h24`),
    /// falling back to `0` (day) vs `count - 1` (night).
    static func pickFrameIndex(source: CGImageSource, night: Bool) -> Int {
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return 0 }
        if let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] {
            for tag in tags {
                let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
                guard (name == "apr" || name == "solar" || name == "h24"),
                      let b64 = CGImageMetadataTagCopyValue(tag) as? String,
                      let data = Data(base64Encoded: b64),
                      let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
                else { continue }
                let pair = (plist["ap"] as? [String: Any]) ?? plist
                if let idx = pair[night ? "d" : "l"] as? Int, idx >= 0, idx < count {
                    return idx
                }
            }
        }
        return night ? (count - 1) : 0
    }

    /// Measures `PhotoContrast.extraDim` on a compact <= 512 px sRGB buffer so even 6K HEICs measure in < 1 ms.
    static func measureExtraDim(image: CGImage, aspect: Double) -> Double {
        let maxSide = 512.0
        let scale = min(1.0, maxSide / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        let rb = w * 4
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: rb, space: srgb,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              )
        else { return 0 }
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let rowBytes = ctx.bytesPerRow
        let pixels = [UInt8](UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: rowBytes * h))
        return PhotoContrast.measure(pixels: pixels, width: w, height: h, bytesPerPixel: 4, rowBytes: rowBytes, aspect: aspect).extraDim
    }
}

// MARK: - Plan B: Live Aerial Video Playback

final class AerialPlayerNSView: NSView {
    private let posterLayer = CALayer()
    private let playerLayer = AVPlayerLayer()
    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        posterLayer.contentsGravity = .resizeAspectFill
        posterLayer.masksToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.masksToBounds = true
        layer?.addSublayer(posterLayer)
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        posterLayer.frame = bounds
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func configure(url: URL, poster: CGImage?) {
        posterLayer.contents = poster
        if currentURL == url, let existing = player {
            if existing.rate == 0 { existing.play() }
            return
        }
        stop()
        currentURL = url
        let item = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        let playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        playerLayer.player = queuePlayer
        player = queuePlayer
        looper = playerLooper
        queuePlayer.play()
    }

    func stop() {
        looper?.disableLooping()
        looper = nil
        player?.pause()
        player?.removeAllItems()
        playerLayer.player = nil
        player = nil
        currentURL = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }

    deinit {
        stop()
    }
}

private struct AerialPlayerSurface: NSViewRepresentable {
    let url: URL
    let poster: CGImage?

    func makeNSView(context: Context) -> AerialPlayerNSView {
        let v = AerialPlayerNSView(frame: .zero)
        v.configure(url: url, poster: poster)
        return v
    }

    func updateNSView(_ nsView: AerialPlayerNSView, context: Context) {
        nsView.configure(url: url, poster: poster)
    }

    static func dismantleNSView(_ nsView: AerialPlayerNSView, coordinator: ()) {
        nsView.stop()
    }
}

/// Live Aerial `.mov` backdrop with the exact same WCAG `extraDim` + day/night dim stack as `PhotoBackdrop`.
struct AerialVideoBackdrop: View {
    let url: URL
    let poster: CGImage?
    let extraDim: Double
    let night: Bool

    var body: some View {
        ZStack {
            AerialPlayerSurface(url: url, poster: poster)
            Color.black.opacity(extraDim)
            Color.black.opacity(night ? SceneryArt.nightDim : SceneryArt.dayDim)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
