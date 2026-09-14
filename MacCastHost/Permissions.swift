import AppKit
import ApplicationServices
import CoreGraphics
import Observation

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
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
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

    /// Prompts for Screen Recording. Unlike preflight, this actually asks — and if the
    /// user has already answered once, macOS silently does nothing, which is why the panel
    /// also offers a direct link to System Settings.
    func requestScreenRecording() {
        hasRequestedScreenRecording = true
        _ = CGRequestScreenCaptureAccess()
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
