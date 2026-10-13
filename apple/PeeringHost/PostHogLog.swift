import PostHog

enum PostHogLog {
    static func info(_ message: String, attributes: [String: Any] = [:]) {
        guard PostHogConfiguration.isConfigured, Analytics.isEnabled else { return }
        PostHogSDK.shared.logger?.info(message, attributes: attributes)
    }

    static func error(_ message: String, attributes: [String: Any] = [:]) {
        guard PostHogConfiguration.isConfigured, Analytics.isEnabled else { return }
        PostHogSDK.shared.logger?.error(message, attributes: attributes)
    }
}
