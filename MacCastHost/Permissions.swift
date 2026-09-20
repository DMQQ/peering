import AppKit
// `@preconcurrency`, for one symbol: `kAXTrustedCheckOptionPrompt` is an imported global `var`, and
// Swift 6 will not let any context read a global mutable variable, this class's `@MainActor`
// included. It is a constant in practice (the framework publishes it once and never writes it), but
// the Accessibility headers cannot say so, having been written long before any of this.
//
// The annotation is on the import rather than at the use site because that is the only place the
// promise can honestly be made: the property belongs to the module, not to the call.
@preconcurrency import ApplicationServices
import CoreGraphics
import Observation
import os
import ScreenCaptureKit

/// The two macOS permissions this app cannot function without, and the difference between
/// checking and requesting them.
///
/// Both failures are silent, which is why they get a dedicated panel rather than being
/// discovered later:
///
/// - Without **Accessibility**, `CGEvent.post` into another application is a no-op. The
///   client connects, sends commands, and nothing happens — no error anywhere.
/// - Without **Screen Recording**, ScreenCaptureKit can emit no frames *and* no error.
///   The client shows a black screen and the host looks perfectly healthy.
///
/// `CGPreflightScreenCaptureAccess()` only *reports* status; it never prompts. Using it as
/// the trigger for a request creates a deadlock where the app never asks and therefore
/// never receives. Requesting is a separate call, and the panel offers it explicitly.
@MainActor
@Observable
final class Permissions {
    private(set) var accessibilityGranted = false
    private(set) var screenRecordingGranted = false

    init() {
        refresh()
    }

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        // CGPreflightScreenCaptureAccess reflects the old CG TCC entry, not the
        // ScreenCaptureKit entry that macOS 15 tracks separately. Probe SCK directly.
        Task { @MainActor in await self.probeScreenCaptureKit() }
    }

    /// Probes ScreenCaptureKit to get its real permission status and, on first run,
    /// register the app in System Settings > Privacy & Security > Screen Recording.
    @discardableResult
    func probeScreenCaptureKit() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            screenRecordingGranted = true
            return true
        } catch {
            screenRecordingGranted = false
            return false
        }
    }

    /// Asks for whatever is missing. Called once at launch.
    ///
    /// Requesting is not the same as checking, and the difference matters: an app that only
    /// ever *checks* accessibility never appears in the System Settings list at all, so a
    /// user who wants to grant it has to add the bundle by hand — having first worked out
    /// where it lives. The request is what creates the entry.
    ///
    /// This cannot nag. macOS shows each prompt once per app and silently ignores later
    /// calls, so a user who has already declined sees nothing.
    func requestMissing() {
        if !accessibilityGranted { requestAccessibility() }
        // SCK is already probed in refresh(); a CGRequest wouldn't add SCKit to Settings.
        if !screenRecordingGranted { requestScreenRecording() }
    }

    /// Prompts for Accessibility. This opens the system dialog / System Settings pane.
    /// The return value is the status *before* the user answers, so it is intentionally
    /// discarded — `refresh()` after the fact is what matters.
    func requestAccessibility() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Prompts for Screen Recording. Probing SCK is the mechanism that registers the app
    /// in System Settings and shows the permission sheet on macOS 15+.
    func requestScreenRecording() {
        Task { @MainActor in await probeScreenCaptureKit() }
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Quits this app and opens it again.
    ///
    /// **The only thing that can make a Screen Recording grant take effect.** macOS reads that
    /// consent when the process starts, so an app that stays running after the user grants it is
    /// an app that keeps capturing nothing until they quit it by hand. "Check again", which sits
    /// next to this button, cannot help with that at all: a check can only report what the
    /// process was granted at launch, and the caption under it currently promises otherwise.
    ///
    /// **Restarted through a shell rather than by asking the workspace for a second instance.**
    /// That is about the listener, not about tidiness: this app binds a port, so a copy opened
    /// while this one is still alive finds the port taken, fails to serve, and leaves the user
    /// with a Mac that looks open and is not hosting. The shell waits for this process to be gone
    /// before opening the app again, which makes the handover sequential instead of a race.
    func relaunch() {
        // Single-quoted for the shell, with any quote in the path closed, escaped and reopened,
        // so a folder named `Peering's App` does not end the string early.
        let path = "'" + Bundle.main.bundleURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open -n \(path)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do {
            try process.run()
        } catch {
            // Deliberately not terminating. A relaunch that could not be arranged leaves the app
            // exactly as it was, which is a working app with a missing permission rather than no
            // app at all, and the button stays available to try again.
            hostLog.error("could not arrange a relaunch: \(String(describing: error), privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }
}

private let hostLog = Logger(subsystem: "pl.dmq.peering.host", category: "permissions")
