import Foundation
import os
import Sparkle

/// What the updater is doing, for a future "检查更新" row in Settings.
enum UpdateStatus: Equatable {
    case idle
    case checking
    case downloading(version: String)
    case ready(version: String)       // downloaded and extracted; installs when no break is on screen
    case error(String)
}

/// A Sparkle 2 `SPUUserDriver` that never shows a window (protocol checked against Sparkle 2.6.4
/// `SPUUserDriver.h`). Every update is accepted, downloaded and extracted silently, and installed
/// with a relaunch as soon as no break is on screen. Errors are logged and swallowed.
/// Sparkle calls all of these on the main thread.
final class SilentUserDriver: NSObject, SPUUserDriver {
    private let log = Logger(subsystem: "app.pausa", category: "update")

    /// Called on the main thread on every change.
    var onStatus: ((UpdateStatus) -> Void)?
    private(set) var status: UpdateStatus = .idle { didSet { if status != oldValue { onStatus?(status) } } }
    /// Latest version Sparkle reported (found, downloading or ready), nil until a check finds one.
    private(set) var latestVersion: String?

    /// Return false while a break is running: the install waits until `breakEnded()`.
    var canInstallNow: () -> Bool = { true }
    /// Persist the scheduler right before the app quits to install.
    var willRelaunch: () -> Void = {}

    private var heldInstall: ((SPUUserUpdateChoice) -> Void)?

    /// Call when a break ends: runs an install that was waiting for it.
    func breakEnded() {
        guard let reply = heldInstall, canInstallNow() else { return }
        heldInstall = nil
        install(reply)
    }

    private func install(_ reply: (SPUUserUpdateChoice) -> Void) {
        log.info("installing update \(self.latestVersion ?? "?", privacy: .public) and relaunching")
        willRelaunch()
        reply(.install)
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest,
          reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Only asked when Info.plist doesn't set SUEnableAutomaticChecks. No dialog: check, no profile.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        status = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = appcastItem.displayVersionString
        latestVersion = version
        log.info("driver: update found \(version, privacy: .public) stage \(String(describing: state.stage.rawValue), privacy: .public) infoOnly \(appcastItem.isInformationOnlyUpdate)")
        if appcastItem.isInformationOnlyUpdate {
            // Nothing to install; "install" would open a web page.
            log.info("information-only update \(version, privacy: .public) ignored")
            status = .idle
            reply(.dismiss)
            return
        }
        // Accept; downloading is silent. The relaunch waits for the break in showReadyToInstallAndRelaunch.
        status = state.stage == .notDownloaded ? .downloading(version: version) : .ready(version: version)
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log.info("driver: no update (\(error.localizedDescription, privacy: .public))")
        status = .idle
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log.error("update failed: \(error.localizedDescription, privacy: .public)")
        heldInstall = nil
        status = .error(error.localizedDescription)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        log.info("driver: download started")
        status = .downloading(version: latestVersion ?? "")
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

    func showDownloadDidReceiveData(ofLength length: UInt64) {}

    func showDownloadDidStartExtractingUpdate() {}

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        status = .ready(version: latestVersion ?? "")
        log.info("driver: ready to install \(self.latestVersion ?? "?", privacy: .public)")
        if canInstallNow() { install(reply) } else {
            log.info("update ready; holding install until the break ends")
            heldInstall = reply
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        // Pausa has no windows that block termination; nothing to retry.
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        status = .idle
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        // Session over (installed, cancelled, or errored). Keep an error visible; otherwise back to idle.
        heldInstall = nil
        if case .error = status { return }
        status = .idle
    }
}
