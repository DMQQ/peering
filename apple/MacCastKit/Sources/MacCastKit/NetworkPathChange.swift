import Foundation

/// Decides when a network path update means open sockets may be half dead.
/// The interface set alone misses a link that drops and returns on the same interfaces, such as a VPN reconnecting or Wi-Fi roaming back, so a lost path counts as a change when it comes back.
public struct NetworkPathChange: Sendable, Equatable {
    private var lastSignature: String?
    private var wasLost = false

    public init() {}

    /// - Returns: whether sockets opened before this update should be replaced.
    public mutating func update(isSatisfied: Bool, interfaceNames: [String]) -> Bool {
        guard isSatisfied else {
            wasLost = lastSignature != nil
            return false
        }
        let signature = interfaceNames.sorted().joined(separator: ",")
        defer {
            lastSignature = signature
            wasLost = false
        }
        // The first update only reports where things already are.
        guard let last = lastSignature else { return false }
        return wasLost || last != signature
    }
}
