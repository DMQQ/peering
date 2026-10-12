import Foundation
import RemoteCore

/// Why a session that had been ready stopped, from a closed set.
public enum SessionEndReason: String, Sendable, CaseIterable {
    case user, hostClosed, unresponsive, transport, backgrounded, quota, error, retryCapped

    public init(failure reason: ClientSession.FailureReason) {
        switch reason {
        case .hostClosed: self = .hostClosed
        case .unresponsive, .unresponsiveAfterCheck: self = .unresponsive
        case .transport, .timedOut: self = .transport
        case .relay: self = .quota
        default: self = .error
        }
    }
}
