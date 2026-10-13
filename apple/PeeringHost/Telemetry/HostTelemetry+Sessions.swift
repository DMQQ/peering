import Foundation
import PeeringKit

extension HostTelemetry {
    /// A phone whose hello names a client that is already open replaces it: the older session is closed here, as `replaced`.
    static func sessionOpened(clientID: String, sessionRef: String?, clientPlatform: String?, viaRelay: Bool) {
        let previous = HostSessionFacts.shared.opened(clientID: clientID, sessionRef: sessionRef, clientPlatform: clientPlatform, viaRelay: viaRelay)
        guard let previous else { return }
        sendEnd(previous, reason: .replaced, bytesSent: 0, droppedFrames: 0, restarts: 0, directPathOpen: false)
    }

    static func sessionStarted(clientID: String, droppedFrames: Int) {
        HostSessionFacts.shared.baseline(clientID: clientID, droppedFrames: droppedFrames)
        var properties: [String: Any] = [:]
        if let facts = HostSessionFacts.shared.peek(clientID: clientID) {
            properties["route"] = facts.viaRelay ? HostEventCodes.Route.relay.rawValue : HostEventCodes.Route.lan.rawValue
            properties["client_platform"] = HostEventCodes.clientPlatformName(facts.clientPlatform)
            if let ref = facts.sessionRef { properties["session_ref"] = ref }
        }
        Analytics.send("host_session_started", properties)
    }

    /// The first reason noted for the client wins; without one the phone closed it.
    static func sessionEnded(clientID: String, bytesSent: Int64, droppedFrames: Int, directPathOpen: Bool) {
        guard let closed = HostSessionFacts.shared.closed(clientID: clientID) else {
            Analytics.send("host_session_ended", [:])
            return
        }
        let reason = closed.entry.endReason ?? .clientClosed
        sendEnd(
            closed.entry, reason: reason, bytesSent: bytesSent, droppedFrames: max(0, droppedFrames - closed.entry.droppedAtStart),
            restarts: closed.encoderRestarts, directPathOpen: directPathOpen
        )
    }

    private static func sendEnd(
        _ entry: HostSessionFacts.Entry, reason: HostEventCodes.EndReason, bytesSent: Int64, droppedFrames: Int, restarts: Int, directPathOpen: Bool
    ) {
        let route: HostEventCodes.Route = entry.viaRelay ? (directPathOpen ? .direct : .relay) : .lan
        let properties = HostEventCodes.endProperties(
            reason: reason, durationSeconds: Int(Date().timeIntervalSince(entry.started)), route: route,
            clientPlatform: entry.clientPlatform, bytesSent: bytesSent, droppedFrames: droppedFrames,
            encoderRestarts: restarts, sessionRef: entry.sessionRef
        )
        Analytics.send("host_session_ended", properties)
    }
}
