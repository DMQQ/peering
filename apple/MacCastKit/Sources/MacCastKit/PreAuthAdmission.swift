import Foundation

/// Whether a new connection from `address` may start a handshake, given the ones that have not authenticated yet.
public enum PreAuthAdmission {
    public static let maximumInTotal = 8
    public static let maximumPerAddress = 2

    public enum Decision: Sendable, Equatable {
        case admit
        case tooManyInTotal
        case tooManyFromAddress
    }

    public static func decide(unauthenticatedAddresses: [String], newAddress: String) -> Decision {
        if unauthenticatedAddresses.count >= maximumInTotal { return .tooManyInTotal }
        if unauthenticatedAddresses.filter({ $0 == newAddress }).count >= maximumPerAddress { return .tooManyFromAddress }
        return .admit
    }

    /// Control frames before the session is ready are hellos and pairing steps, a few hundred bytes each.
    public static let maximumFrameBeforeReady: UInt32 = 64 * 1024
}
