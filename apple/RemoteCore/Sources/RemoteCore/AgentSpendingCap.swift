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
