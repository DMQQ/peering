import AppKit
import Foundation
import MacCastKit
import PostHog

/// Anonymous usage counts from the Mac app, on by default and off with one switch in Settings.
///
/// Every value is from a closed set (an enum or a bool): never a window title, an app name, a path, a device name or an address.
enum Analytics {
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: PreferenceKeys.analyticsEnabled) as? Bool ?? true
    }

    static func hostLaunched() {
        send("host_launched", [:])
    }

    enum Permission: String {
        case accessibility, screenRecording
    }

    static func permissionChanged(_ permission: Permission, granted: Bool) {
        send("permission_changed", ["permission": permission.rawValue, "granted": String(granted)])
    }

    enum Event: String {
        case sessionStarted = "host_session_started"
        case sessionEnded = "host_session_ended"
        case privacyModeChanged = "host_privacy_mode_changed"
        case lidCloseChanged = "host_lid_close_changed"
        case keepAwakeScheduleChanged = "host_keep_awake_schedule_changed"
        case wakeScheduleChanged = "host_wake_schedule_changed"
        case captureSourceChanged = "host_capture_source_changed"
        case unpaired = "host_unpaired"
        case unpairedAll = "host_unpaired_all"
        case clientDisconnected = "host_client_disconnected"
        case updateChecked = "host_update_checked"
        case updateInstalled = "host_update_installed"
    }

    static func track(_ event: Event) {
        send(event.rawValue, [:])
    }

    static func settingChanged(_ name: String, to value: String) {
        send("setting_changed", ["setting": name, "value": value])
    }

    /// Watches the preferences a user can flip, so every switch in the settings screen is counted without a line in each view.
    static func observeSettings() {
        SettingsObserver.shared.start()
    }

    static func serverStartFailed() {
        send("host_start_failed", [:])
    }

    private static func send(_ event: String, _ properties: [String: String]) {
        guard isEnabled, PostHogConfiguration.isConfigured else { return }
        var props: [String: Any] = properties
        props["$process_person_profile"] = false
        props["app_version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        props["app_build"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        props["os_major"] = String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        PostHogSDK.shared.capture(event, properties: props)
    }
}

nonisolated private final class SettingsObserver: NSObject {
    nonisolated(unsafe) static let shared = SettingsObserver()
    private static let keys = [
        PreferenceKeys.analyticsEnabled, "hostShowsPreview", "captureResolution", "captureFrameRate", "captureCodec",
        "keepRunningWithLidClosed", "keepAwakeScheduleEnabled", "preventLidCloseSleep",
    ]
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        for key in Self.keys {
            UserDefaults.standard.addObserver(self, forKeyPath: key, options: [.new], context: nil)
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let keyPath, let new = change?[.newKey] else { return }
        let value: String
        switch new {
        case let bool as Bool: value = String(bool)
        case let text as String: value = text
        case let number as Int: value = String(number)
        default: return
        }
        Task { @MainActor in
            if keyPath == PreferenceKeys.analyticsEnabled, value == "false" { return }
            Analytics.settingChanged(keyPath.replacingOccurrences(of: "Peering.", with: ""), to: value)
        }
    }
}
