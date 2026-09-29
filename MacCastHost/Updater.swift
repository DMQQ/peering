import Sparkle
import SwiftUI

/// The updater: a check against the appcast the relay serves, and the "Check for Updates…" that
/// both the menu and About offer.
///
/// Sparkle does all of the work — fetching the feed, verifying the signature, downloading,
/// unpacking and replacing this app — and this is the thin part that owns it and tells the UI what
/// it is doing. Nothing here decides *what* an update is: the feed URL and the public key it is
/// verified against are in `MacCastHost-Info.plist`, because those are the two things a release
/// changes and neither is a decision this file is entitled to make.
///
/// The host app is not sandboxed, so an update can be installed in place. Sandboxed apps need
/// Sparkle's XPC services and a set of entitlements; if the host is ever sandboxed, that is the
/// thing that will break first, and it will break as an update that downloads and then refuses to
/// install rather than as anything more obvious.
@MainActor
@Observable
final class Updater {
    /// Whether a check can be started at this moment.
    ///
    /// Sparkle's own answer rather than a flag of ours: it is false while a check is running, while
    /// an update is being installed, and for a short while after a check that found nothing, and
    /// every one of those is a state a button must be disabled in. Guessing at it here would mean
    /// guessing at three states instead of reading one.
    private(set) var canCheck = false

    /// The version the last check found, or nil when this build is current.
    private(set) var availableVersion: String?

    /// Whether the found update has been downloaded in the background, so ``install()`` can
    /// restart into it without Sparkle's window.
    var readyToInstall: Bool { installNow != nil }

    private var installNow: (() -> Void)?

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let delegate = Delegate()
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        // `startingUpdater: true` is what schedules the hourly check; the standard user driver is
        // Sparkle's own window, which is the right one — an updater with a bespoke interface is an
        // updater somebody has to maintain, and this app has one screen's worth of design to spend
        // and it is spent on the picture.
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
        // Silent: downloads in the background and fills the banner without Sparkle's window.
        controller.updater.checkForUpdatesInBackground()
    }

    private final class Delegate: NSObject, SPUUpdaterDelegate {
        var onFound: (@MainActor (String?) -> Void)?
        var onReady: (@MainActor (@escaping () -> Void) -> Void)?

        func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
            let version = item.displayVersionString
            Task { @MainActor in self.onFound?(version) }
        }

        func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
            Task { @MainActor in self.onFound?(nil) }
        }

        /// Taking the block keeps Sparkle from prompting; the banner offers it instead, and an
        /// update nobody clicks still installs when the app quits.
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
        controller.checkForUpdates(nil)
    }

    /// Restarts into the downloaded update, or falls back to Sparkle's window while it is not.
    func install() {
        if let installNow { installNow() } else { check() }
    }
}
