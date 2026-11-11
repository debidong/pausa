import Foundation
import Sparkle
import os

/// Single-track auto-update lifecycle state shared by Sparkle callbacks and Settings / Popover UI.
enum UpdatePhase: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case downloading(version: String)
    case readyToInstall(version: String)
    case installing(version: String)
    case failed(message: String)
}

/// Pure, Sparkle-free state machine driving `UpdatePhase` transitions.
struct UpdateStateMachine: Equatable, Sendable {
    enum Event: Equatable, Sendable {
        case checkStarted
        case updateFound(version: String, alreadyDownloaded: Bool, infoOnly: Bool)
        case downloadStarted(fallbackVersion: String?)
        case notFound
        case readyToRelaunch(fallbackVersion: String?)
        case installProceeded
        case installed
        case sessionDismissed
        case failed(String)
    }

    private(set) var phase: UpdatePhase = .idle
    private(set) var latestVersion: String?

    @discardableResult
    mutating func send(_ event: Event) -> UpdatePhase {
        switch event {
        case .checkStarted:
            phase = .checking

        case .updateFound(let version, let alreadyDownloaded, let infoOnly):
            if infoOnly {
                phase = .idle
            } else {
                if !version.isEmpty { latestVersion = version }
                let resolved = resolvedVersion(version)
                phase = alreadyDownloaded ? .readyToInstall(version: resolved) : .downloading(version: resolved)
            }

        case .downloadStarted(let fallback):
            let resolved = resolvedVersion(fallback)
            phase = .downloading(version: resolved)

        case .notFound:
            phase = .upToDate

        case .readyToRelaunch(let fallback):
            let resolved = resolvedVersion(fallback)
            phase = .readyToInstall(version: resolved)

        case .installProceeded:
            let resolved = resolvedVersion(nil)
            phase = .installing(version: resolved)

        case .installed:
            phase = .idle

        case .sessionDismissed:
            switch phase {
            case .upToDate, .failed, .idle:
                break
            case .checking, .downloading, .readyToInstall, .installing:
                phase = .idle
            }

        case .failed(let message):
            phase = .failed(message: message)
        }
        return phase
    }

    private mutating func resolvedVersion(_ candidate: String?) -> String {
        if let candidate, !candidate.isEmpty {
            latestVersion = candidate
            return candidate
        }
        switch phase {
        case .downloading(let v), .readyToInstall(let v), .installing(let v):
            if !v.isEmpty {
                latestVersion = v
                return v
            }
            return latestVersion ?? ""
        case .idle, .checking, .upToDate, .failed:
            return latestVersion ?? ""
        }
    }
}

/// Coordinates Sparkle 2 (`SPUUpdater` + `SilentUserDriver`) through a single `UpdateStateMachine`
/// and a single deferred-install continuation slot.
final class Updater: NSObject, SPUUpdaterDelegate {
    private enum DeferredInstall {
        case driverChoice((SPUUserUpdateChoice) -> Void)
        case delegateRelaunch(() -> Void)

        func proceed(willRelaunch: () -> Void) {
            switch self {
            case .driverChoice(let reply):
                willRelaunch()
                reply(.install)
            case .delegateRelaunch(let handler):
                handler()   // `updaterWillRelaunchApplication` runs `willRelaunch()` right before exit
            }
        }
    }

    private(set) var machine = UpdateStateMachine()
    private var deferredInstall: DeferredInstall?

    var phase: UpdatePhase { machine.phase }
    var latestVersion: String? { machine.latestVersion }
    /// Fired on the main thread whenever `phase` changes.
    var onPhaseChange: ((UpdatePhase) -> Void)?

    /// Return false while a break or full-screen preview is on screen: installs wait until clearance.
    var canInstallNow: () -> Bool = { true }
    /// Called right before Sparkle relaunches the app, to persist work spans and `Scheduler.Saved`.
    var willRelaunch: () -> Void = {}

    let driver = SilentUserDriver()
    private lazy var updater: SPUUpdater = {
        wireDriver()
        return SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
    }()
    private var started = false
    private let log = Logger(subsystem: "app.pausa", category: "update")

    override init() {
        super.init()
        wireDriver()
    }

    private func wireDriver() {
        driver.onUserCheckStarted = { [weak self] in self?.transition(.checkStarted) }
        driver.onUpdateFound = { [weak self] version, downloaded, infoOnly in
            self?.transition(.updateFound(version: version, alreadyDownloaded: downloaded, infoOnly: infoOnly))
        }
        driver.onDownloadStarted = { [weak self] in
            self?.transition(.downloadStarted(fallbackVersion: self?.machine.latestVersion))
        }
        driver.onUpdateNotFound = { [weak self] in self?.transition(.notFound) }
        driver.onReadyToInstall = { [weak self] reply in self?.handleDriverReady(reply) }
        driver.onInstalledAndRelaunched = { [weak self] in self?.transition(.installed) }
        driver.onDismissed = { [weak self] in
            self?.deferredInstall = nil
            self?.transition(.sessionDismissed)
        }
        driver.onError = { [weak self] message in
            self?.deferredInstall = nil
            self?.transition(.failed(message))
        }
    }

    private func transition(_ event: UpdateStateMachine.Event) {
        let previous = machine.phase
        let next = machine.send(event)
        if next != previous { onPhaseChange?(next) }
    }

    /// Starts scheduled checks (interval from Info.plist SUScheduledCheckInterval). Safe to call twice.
    func start() {
        guard !started else { return }
        do { try updater.start(); started = true } catch { NSLog("Pausa updater failed to start: \(error)") }
    }

    /// Manual "检查更新". Starts the updater first if needed; silent either way.
    func checkForUpdates() {
        start()
        guard started, updater.canCheckForUpdates else { return }
        transition(.checkStarted)
        updater.checkForUpdates()
    }

    /// The popover's 「有新版本」 / About's 「立即重启」: install a ready update now. No-op while blocked.
    func installNow() {
        retryHeldInstall()
    }

    /// Call when a break or preview ends: runs an install that was postponed because of an active overlay.
    func retryHeldInstall() {
        guard canInstallNow(), let deferred = deferredInstall else { return }
        deferredInstall = nil
        log.info("installing held update \(self.machine.latestVersion ?? "?", privacy: .public) and relaunching")
        transition(.installProceeded)
        deferred.proceed(willRelaunch: willRelaunch)
    }

    private func handleDriverReady(_ reply: @escaping (SPUUserUpdateChoice) -> Void) {
        transition(.readyToRelaunch(fallbackVersion: machine.latestVersion))
        log.info("driver: ready to install \(self.machine.latestVersion ?? "?", privacy: .public)")
        if canInstallNow() {
            deferredInstall = nil
            transition(.installProceeded)
            DeferredInstall.driverChoice(reply).proceed(willRelaunch: willRelaunch)
        } else {
            log.info("update ready; holding install until overlay clears")
            deferredInstall = .driverChoice(reply)
        }
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log.info("found update \(item.displayVersionString, privacy: .public) build \(item.versionString, privacy: .public)")
        guard !item.isInformationOnlyUpdate else { return }
        if case .readyToInstall = machine.phase { return }
        if case .installing = machine.phase { return }
        transition(.updateFound(version: item.displayVersionString, alreadyDownloaded: false, infoOnly: false))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        transition(.notFound)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let ns = error as NSError
        let code = ns.code
        log.error("check aborted: \(ns.domain, privacy: .public) \(code) \(ns.localizedDescription, privacy: .public) underlying: \(String(describing: ns.userInfo[NSUnderlyingErrorKey]), privacy: .public)")
        if code != Int(SUError.noUpdateError.rawValue) {
            deferredInstall = nil
            transition(.failed(ns.localizedDescription))
        }
    }

    func shouldPostponeRelaunch(version: String?, untilInvoking installHandler: @escaping () -> Void) -> Bool {
        if canInstallNow() {
            log.info("relaunch not postponed")
            transition(.installProceeded)
            return false
        }
        log.info("relaunch postponed: overlay on screen")
        transition(.readyToRelaunch(fallbackVersion: version))
        deferredInstall = .delegateRelaunch(installHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        shouldPostponeRelaunch(version: item.displayVersionString, untilInvoking: installHandler)
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        log.info("will relaunch")
        willRelaunch()
    }
}
