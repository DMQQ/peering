import Foundation

/// A chat's limit, set from the phone: past it, messages waiting behind a turn are held until the person sends one on.
public struct AgentSpendingCap: Codable, Equatable, Sendable {
    public var costUSD: Double?
    /// Of the context window, 1 to 100.
    public var contextPercent: Int?

    public init(costUSD: Double? = nil, contextPercent: Int? = nil) {
        self.costUSD = costUSD
        self.contextPercent = contextPercent
    }

    public var isEmpty: Bool { costUSD == nil && contextPercent == nil }
}

/// Whether a client may send the away-from-the-Mac requests: ``AgentRequest/setAlertPreference(decisionsOnly:)``,
/// ``AgentRequest/setSpendingCap(sessionID:cap:)``, ``AgentRequest/releaseHeld(sessionID:)`` and
/// ``AgentRequest/approvePlan(sessionID:approvalID:acceptEditsForTurn:)``. They came without a protocol bump, so
/// only an explicit `true` in ``ServerHello/supportsAgentAwayControls`` counts.
public enum AgentAwayControlsSupport {
    public static func maySend(toHostDeclared declared: Bool?) -> Bool {
        declared == true
    }
}
