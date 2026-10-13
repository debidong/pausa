import Foundation
import Sparkle
import os

/// Thin wrapper around Sparkle with a silent user driver (SilentUserDriver). No UI yet.
/// `onStatus` / `status` are the new state for Settings; `onState` is kept for compatibility.
final class Updater: NSObject, SPUUpdaterDelegate {
    enum State: Equatable { case idle, checking, upToDate, available(String), failed }

    /// Called on the main thread when the update state changes (for the future About row / menu item).
    var onState: ((State) -> Void)?
    /// Return false while a break is running: installs/relaunches wait until it ends.
    var canInstallNow: () -> Bool = { true }
    /// Called right before Sparkle relaunches the app, to persist the timer and `deferUsed`.
    var willRelaunch: () -> Void = {}

    private var pendingInstall: (() -> Void)?
    /// No Sparkle windows: see SilentUserDriver. Its hooks forward to the two above.
    let driver = SilentUserDriver()
    private lazy var updater: SPUUpdater = {
        driver.canInstallNow = { [unowned self] in self.canInstallNow() }
        driver.willRelaunch = { [unowned self] in self.willRelaunch() }
        return SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
    }()
    private var started = false
    private let log = Logger(subsystem: "app.pausa", category: "update")

    /// For the Settings "检查更新" row: idle / checking / downloading / ready / error.
    var status: UpdateStatus { driver.status }
    var latestVersion: String? { driver.latestVersion }
    var onStatus: ((UpdateStatus) -> Void)? {
        get { driver.onStatus }
        set { driver.onStatus = newValue }
    }

    /// Starts scheduled checks (interval from Info.plist SUScheduledCheckInterval). Not called
    /// automatically yet; call once after launch. Safe to call twice.
    func start() {
        guard !started else { return }
        do { try updater.start(); started = true } catch { NSLog("Pausa updater failed to start: \(error)") }
    }

    /// Manual "检查更新". Starts the updater first if needed; silent either way.
    func checkForUpdates() {
        start()
        guard started, updater.canCheckForUpdates else { return }
        onState?(.checking)
        updater.checkForUpdates()
    }

    /// The popover's 「有新版本」 / About's 「立即重启」: install a ready update now. No-op during a break.
    func installNow() {
        guard canInstallNow() else { return }
        breakEnded()
    }

    /// Call when a break ends; runs an install that was postponed because of it.
    func breakEnded() {
        let run = pendingInstall
        pendingInstall = nil
        run?()
        driver.breakEnded()
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log.info("found update \(item.displayVersionString, privacy: .public) build \(item.versionString, privacy: .public)")
        onState?(.available(item.displayVersionString))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        onState?(.upToDate)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let ns = error as NSError
        let code = ns.code
        log.error("check aborted: \(ns.domain, privacy: .public) \(code) \(ns.localizedDescription, privacy: .public) underlying: \(String(describing: ns.userInfo[NSUnderlyingErrorKey]), privacy: .public)")
        if code != Int(SUError.noUpdateError.rawValue) { onState?(.failed) }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        if canInstallNow() { log.info("relaunch not postponed"); return false }
        log.info("relaunch postponed: break on screen")
        pendingInstall = installHandler
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        log.info("will relaunch")
        willRelaunch()
    }
}
