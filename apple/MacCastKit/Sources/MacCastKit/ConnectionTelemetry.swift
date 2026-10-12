import Foundation
import RemoteCore

/// The properties a connection event carries. Built here from closed sets and numbers so nothing a person typed, and no name, address or id, can reach an event.
public enum ConnectionTelemetry {
    public struct Context: Sendable {
        public var routes: String
        public var network: NetworkContext
        public var networkChangesDuringSession: Int
        /// The hello's `hostPlatform`.
        public var hostPlatform: String?
        public var quotaBucket: String?

        public init(routes: String, network: NetworkContext, networkChangesDuringSession: Int, hostPlatform: String?, quotaBucket: String?) {
            self.routes = routes
            self.network = network
            self.networkChangesDuringSession = networkChangesDuringSession
            self.hostPlatform = hostPlatform
            self.quotaBucket = quotaBucket
        }
    }

    /// The host app version and OS are not in the hello, so the host is described by its platform alone.
    public static func hostPlatformName(_ platform: String?) -> String {
        switch platform {
        case "macos": "mac"
        case "windows": "windows"
        default: "unknown"
        }
    }

    public static func properties(for context: Context, diagnosis: FailureDiagnosis?) -> [String: any Sendable] {
        var properties: [String: any Sendable] = [
            "route_attempts": context.routes,
            "network_interface": context.network.interface,
            "is_expensive": context.network.isExpensive,
            "is_constrained": context.network.isConstrained,
            "network_path_changes": context.networkChangesDuringSession,
            "host_platform": hostPlatformName(context.hostPlatform),
        ]
        if let bucket = context.quotaBucket { properties["quota_remaining_bucket"] = bucket }
        guard let diagnosis else { return properties }
        properties["stage"] = diagnosis.stage.rawValue
        if let detail = diagnosis.detail {
            properties["error_domain"] = detail.domain.rawValue
            properties["error_code"] = detail.code
        }
        if let value = diagnosis.millisecondsToReady { properties["ms_to_ready"] = value }
        if let value = diagnosis.lastFrameAgeMilliseconds { properties["last_frame_age_ms"] = value }
        if let value = diagnosis.lastPongAgeMilliseconds { properties["last_pong_age_ms"] = value }
        if let value = diagnosis.roundTripMilliseconds { properties["rtt_ms"] = value }
        return properties
    }

    public static func endProperties(
        reason: SessionEndReason, durationSeconds: Int, reconnects: Int, videoBytes: Int64, droppedFrames: Int
    ) -> [String: any Sendable] {
        [
            "end_reason": reason.rawValue,
            "duration_s": durationSeconds,
            "reconnects": reconnects,
            "video_bytes_bucket": ConnectionBuckets.bytes(videoBytes),
            "dropped_frames_bucket": ConnectionBuckets.droppedFrames(droppedFrames),
        ]
    }
}
