import Foundation

/// The closed sets and buckets the Mac host's session and error events draw from.
public enum HostEventCodes {
    public enum EndReason: String, Sendable, CaseIterable {
        case clientClosed, silence, backgroundedSilence, forgotten, hostStopped, error, replaced
    }

    public enum Route: String, Sendable, CaseIterable {
        case lan, relay, direct
    }

    public enum ErrorCode: String, Sendable, CaseIterable {
        case captureFailed, captureStopped, permissionRevoked, encoderFailed, relayDisconnected, relayRegistrationFailed
        case virtualDisplayFailed, agentCrashed, fileTransferFailed, pairingRefused, hookInstallFailed
    }

    /// `nil` is a phone from before the field, which is an iPhone build.
    public static func clientPlatformName(_ platform: String?) -> String {
        switch platform {
        case nil, "ios": "ios"
        case "android": "android"
        default: "unknown"
        }
    }

    public static func encoderRestarts(_ count: Int) -> Int {
        min(max(count, 0), 20)
    }

    public static func endProperties(
        reason: EndReason, durationSeconds: Int, route: Route, clientPlatform: String?,
        bytesSent: Int64, droppedFrames: Int, encoderRestarts: Int, sessionRef: String?
    ) -> [String: any Sendable] {
        var properties: [String: any Sendable] = [
            "end_reason": reason.rawValue,
            "duration_s": max(durationSeconds, 0),
            "route": route.rawValue,
            "client_platform": clientPlatformName(clientPlatform),
            "bytes_sent_bucket": ConnectionBuckets.bytes(bytesSent),
            "dropped_frames_bucket": ConnectionBuckets.droppedFrames(droppedFrames),
            "encoder_restarts": Self.encoderRestarts(encoderRestarts),
        ]
        if let sessionRef = SessionRef.sanitized(sessionRef) { properties["session_ref"] = sessionRef }
        return properties
    }
}
