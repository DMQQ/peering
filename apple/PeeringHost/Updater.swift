import Sparkle
import SwiftUI

/// The updater: a check against the appcast the relay serves, and the "Check for Updates…" that
/// both the menu and About offer.
@MainActor
@Observable
final class Updater {
    /// Whether a check can be started at this moment.
    private(set) var canCheck = false

    /// The version the last check found, or nil when this build is current.
    private(set) var availableVersion: String?

    var readyToInstall: Bool { installNow != nil }

    /// Sparkle reports `canCheckForUpdates` false for as long as a downloaded update is waiting to
    /// install, which is exactly when "Restart" must work.
    var canInstall: Bool { readyToInstall || canCheck }

    private var installNow: (() -> Void)?

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let delegate = Delegate()
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )

        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] _, _ in
            // Hopped rather than assumed. KVO is not required to call this back on the thread that
            // changed the value, and `@Observable` state written off the main actor is a data race
            // the compiler cannot see through the Objective-C boundary.
            Task { @MainActor in
                guard let self else { return }
                self.canCheck = self.controller.updater.canCheckForUpdates
            }
        }

        delegate.onFound = { [weak self] version in self?.availableVersion = version }
        delegate.onReady = { [weak self] install in self?.installNow = install }
        controller.updater.checkForUpdatesInBackground()
    }

    private final class Delegate: NSObject, SPUUpdaterDelegate {
        var onFound: (@MainActor (String?) -> Void)?
        var onReady: (@MainActor (@escaping () -> Void) -> Void)?

        func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
            let version = item.displayVersionString
            Task { @MainActor in self.onFound?(version) }
        }

        func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
            // Sparkle reports "already up to date" through this too, and that is not a failure.
            if (error as NSError).code == Int(SUError.noUpdateError.rawValue) { return }
            Analytics.failed(error, in: .update)
        }

        func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
            Task { @MainActor in self.onFound?(nil) }
        }

        func updater(
            _ updater: SPUUpdater,
            willInstallUpdateOnQuit item: SUAppcastItem,
            immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
        ) -> Bool {
            let version = item.displayVersionString
            nonisolated(unsafe) let install = immediateInstallHandler
            Task { @MainActor in
                self.onFound?(version)
                self.onReady?(install)
            }
            return true
        }
    }

    func check() {
        Analytics.track(.updateChecked)
        controller.checkForUpdates(nil)
    }

    func install() {
        Analytics.track(.updateInstalled)
        if let installNow { installNow() } else { check() }
    }
}
