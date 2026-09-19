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

    /// Both are evaluated at process start, so a grant made while the app is running does
    /// not take effect until relaunch. The UI says so rather than appearing broken.
    private(set) var hasRequestedScreenRecording = false

    var allGranted: Bool { accessibilityGranted && screenRecordingGranted }

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
        hasRequestedScreenRecording = true
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
}
