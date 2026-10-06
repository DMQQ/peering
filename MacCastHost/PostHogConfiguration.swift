import Foundation
import PostHog

enum PostHogConfiguration {
    nonisolated(unsafe) private(set) static var isConfigured = false

    /// Info.plist first because a shipped app has no environment: the Xcode scheme's variables exist only when launched from Xcode.
    private static func value(_ plistKey: String, env: String) -> String? {
        [Bundle.main.object(forInfoDictionaryKey: plistKey) as? String, ProcessInfo.processInfo.environment[env]]
            .compactMap { $0 }
            .first { !$0.isEmpty }
    }

    static func setup() {
        guard let projectToken = value("PostHogProjectToken", env: "POSTHOG_PROJECT_TOKEN"),
              let host = value("PostHogHost", env: "POSTHOG_HOST")
        else { return }

        let config = PostHogConfig(projectToken: projectToken, host: host)
        config.optOut = !Analytics.isEnabled
        config.personProfiles = .never
        config.disableGeoIp = true
        config.setDefaultPersonProperties = false
        config.captureScreenViews = false
        config.preloadFeatureFlags = false
        config.errorTrackingConfig.autoCapture = true
        config.logs.serviceName = "maccast-host"
        config.setBeforeSend { event in
            for key in ["$ip", "$timezone", "$device_name", "$network_wifi_ssid"] { event.properties.removeValue(forKey: key) }
            return event
        }
        PostHogSDK.shared.setup(config)
        isConfigured = true
    }

    /// Crash reports and the agent events go through the same SDK, so the one switch covers them too.
    static func setEnabled(_ enabled: Bool) {
        guard isConfigured else { return }
        if enabled { PostHogSDK.shared.optIn() } else { PostHogSDK.shared.optOut() }
    }
}
