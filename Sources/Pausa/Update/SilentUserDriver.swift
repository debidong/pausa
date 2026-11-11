import Foundation
import os
import Sparkle

/// Stateless `SPUUserDriver` adapter (protocol checked against Sparkle 2.6.4 `SPUUserDriver.h`).
/// Never presents Sparkle windows; forwards every lifecycle callback to `Updater`'s explicit
/// `UpdateStateMachine` on the main thread.
final class SilentUserDriver: NSObject, SPUUserDriver {
    private let log = Logger(subsystem: "app.pausa", category: "update")

    var onUserCheckStarted: (() -> Void)?
    var onUpdateFound: ((_ version: String, _ alreadyDownloaded: Bool, _ infoOnly: Bool) -> Void)?
    var onDownloadStarted: (() -> Void)?
    var onUpdateNotFound: (() -> Void)?
    var onReadyToInstall: ((@escaping (SPUUserUpdateChoice) -> Void) -> Void)?
    var onInstalledAndRelaunched: (() -> Void)?
    var onDismissed: (() -> Void)?
    var onError: ((String) -> Void)?

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Only asked when Info.plist doesn't set SUEnableAutomaticChecks. No dialog: check, no profile.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        onUserCheckStarted?()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = appcastItem.displayVersionString
        let infoOnly = appcastItem.isInformationOnlyUpdate
        log.info("driver: update found \(version, privacy: .public) stage \(String(describing: state.stage.rawValue), privacy: .public) infoOnly \(infoOnly)")
        onUpdateFound?(version, state.stage != .notDownloaded, infoOnly)
        if infoOnly {
            // Nothing to install; "install" would open a web page.
            log.info("information-only update \(version, privacy: .public) ignored")
            reply(.dismiss)
            return
        }
        // Accept; downloading is silent. Relaunch clearance is gated in showReady(toInstallAndRelaunch:).
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log.info("driver: no update (\(error.localizedDescription, privacy: .public))")
        onUpdateNotFound?()
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log.error("update failed: \(error.localizedDescription, privacy: .public)")
        onError?(error.localizedDescription)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        log.info("driver: download started")
        onDownloadStarted?()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

    func showDownloadDidReceiveData(ofLength length: UInt64) {}

    func showDownloadDidStartExtractingUpdate() {}

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        onReadyToInstall?(reply)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        // Pausa has no windows that block termination; nothing to retry.
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        onInstalledAndRelaunched?()
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        onDismissed?()
    }
}
