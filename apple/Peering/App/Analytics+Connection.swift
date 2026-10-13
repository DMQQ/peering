import Foundation
import PeeringKit
import RemoteCore
import UIKit

/// The connection events. Every value is a closed set, a bucket or a number (see ``ConnectionTelemetry``): never a Mac's name, an address, a port or an id.
extension Analytics {
    static func sessionStarted(path: String, plan: RelayPlan?, millisecondsToReady: Int?, telemetry: [String: any Sendable]) {
        setSessionContext(path: path, plan: plan?.rawValue)
        var properties: [String: Any] = ["path": path, "plan": plan?.rawValue ?? "unknown"]
        properties.merge(telemetry) { _, new in new }
        if let millisecondsToReady { properties["ms_to_ready"] = millisecondsToReady }
        send("session_started", properties)
    }

    /// `first_picture_ms` is absent when no picture ever arrived, which on a relayed session is how a network blocking video shows up. `end_reason` and the tallies come from ``ConnectionTelemetry/endProperties(reason:durationSeconds:reconnects:videoBytes:droppedFrames:)``.
    static func sessionEnded(path: String, video: VideoDeliveryRecord?, telemetry: [String: any Sendable]) {
        clearSessionPath()
        var properties: [String: Any] = ["path": path]
        properties.merge(videoProperties(video)) { _, new in new }
        properties.merge(telemetry) { _, new in new }
        send("session_ended", properties)
    }

    /// `video_recorded` is false when the session had no wire to ask, which is not the same as a wire that never delivered a picture.
    static func videoProperties(_ video: VideoDeliveryRecord?) -> [String: Any] {
        guard let video else { return ["video_recorded": false] }
        var properties: [String: Any] = [
            "video_recorded": true,
            "video_transport": video.transport.rawValue,
            "fell_back": video.fellBack,
        ]
        if let milliseconds = video.firstPictureMilliseconds { properties["first_picture_ms"] = milliseconds }
        return properties
    }

    /// `afterReady` tells a drop mid-session from a connection that never came up, and `video` is what the dropped session's picture went through, since a drop is how a network that blocks video usually ends. `appState` and `pictureInPictureActive` tell a drop the network caused from one iOS caused by freezing the app. `consecutiveDrops` is the run of silent drops the retry cap counts.
    static func connectFailed(
        afterReady: Bool, reason: String, path: String, reconnectAttempt: Int,
        secondsIntoSession: Int?, appState: String, pictureInPictureActive: Bool, video: VideoDeliveryRecord?,
        consecutiveDrops: Int, telemetry: [String: any Sendable]
    ) {
        var properties: [String: Any] = [
            "after_ready": String(afterReady), "reason": reason, "path": path,
            "reconnect_attempt": String(reconnectAttempt), "app_state": appState,
            "pip_active": String(pictureInPictureActive), "consecutive_drops": consecutiveDrops,
        ]
        if let secondsIntoSession { properties["seconds_into_session"] = String(secondsIntoSession) }
        properties.merge(videoProperties(video)) { _, new in new }
        properties.merge(telemetry) { _, new in new }
        send("connect_failed", properties)
    }

    static func name(of state: UIApplication.State) -> String {
        switch state {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}
