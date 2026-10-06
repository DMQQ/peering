import AppKit
// `@preconcurrency`, for one symbol: `kAXTrustedCheckOptionPrompt` is an imported global `var`, and
// Swift 6 will not let any context read a global mutable variable, this class's `@MainActor`
// included. It is a constant in practice (the framework publishes it once and never writes it), but
// the Accessibility headers cannot say so, having been written long before any of this.
@preconcurrency import ApplicationServices
import CoreGraphics
import Observation
import os
import ScreenCaptureKit

/// The two macOS permissions this app cannot function without, and the difference between
/// checking and requesting them.
@MainActor
@Observable
final class Permissions {
    private(set) var accessibilityGranted = false
    private(set) var screenRecordingGranted = false
    private(set) var hasCompletedInitialCheck = false
    private(set) var screenRecordingCheckInProgress = false

    var allRequiredGranted: Bool {
        hasCompletedInitialCheck && accessibilityGranted && screenRecordingGranted
    }

#if DEBUG
    private var isForcingPermissionOnboarding: Bool {
        ProcessInfo.processInfo.arguments.contains("-Peering.forcePermissionOnboarding")
    }
#endif

    init() {
#if DEBUG
        // A safe visual-test hook: it can only remove capabilities, never manufacture a grant.
        // Launch with `-Peering.forcePermissionOnboarding` to inspect first-run setup on a Mac
        // whose real TCC permissions are already configured.
        if ProcessInfo.processInfo.arguments.contains("-Peering.forcePermissionOnboarding") {
            hasCompletedInitialCheck = true
            return
        }
#endif
        refresh()
    }

    func refresh() {
#if DEBUG
        if isForcingPermissionOnboarding {
            accessibilityGranted = false
            screenRecordingGranted = false
            hasCompletedInitialCheck = true
            return
        }
#endif
        refreshAccessibility()
        // CGPreflightScreenCaptureAccess reflects the old CG TCC entry, not the
        // ScreenCaptureKit entry that macOS 15 tracks separately, so SCK stays the authority.
        if !hasCompletedInitialCheck, CGPreflightScreenCaptureAccess() {
            screenRecordingGranted = true
            hasCompletedInitialCheck = true
        }
        Task { @MainActor in await self.probeScreenCaptureKit() }
    }

    /// Accessibility changes take effect without a relaunch, so the onboarding screen can
    /// notice the checkbox being switched on without repeatedly touching ScreenCaptureKit.
    func refreshAccessibility() {
#if DEBUG
        if isForcingPermissionOnboarding {
            accessibilityGranted = false
            return
        }
#endif
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Probes ScreenCaptureKit to get its real permission status and, on first run,
    /// register the app in System Settings > Privacy & Security > Screen Recording.
    @discardableResult
    func probeScreenCaptureKit() async -> Bool {
#if DEBUG
        if isForcingPermissionOnboarding {
            screenRecordingGranted = false
            hasCompletedInitialCheck = true
            return false
        }
#endif
        guard !screenRecordingCheckInProgress else { return screenRecordingGranted }
        screenRecordingCheckInProgress = true
        defer {
            screenRecordingCheckInProgress = false
            hasCompletedInitialCheck = true
        }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            screenRecordingGranted = true
            return true
        } catch {
            hostLog.notice("the ScreenCaptureKit check did not pass: \(error.localizedDescription, privacy: .public)")
            screenRecordingGranted = false
            return false
        }
    }

    /// Asks for whatever is missing. Called once at launch.
    func requestMissing() {
        if !accessibilityGranted { requestAccessibility() }
        // SCK is already probed in refresh(); a CGRequest wouldn't add SCKit to Settings.
        if !screenRecordingGranted { requestScreenRecording() }
    }

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
            hostLog.error("could not arrange a relaunch: \(String(describing: error), privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }
}

private let hostLog = Logger(subsystem: "pl.dmq.peering.host", category: "permissions")
