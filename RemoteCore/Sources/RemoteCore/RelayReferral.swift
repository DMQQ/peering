import Foundation

/// What the relay says about this device's invite code and the extra daily relay time it has earned.
public struct RelayReferral: Sendable, Equatable {
    public let code: String
    /// Added to each daily window right now: zero once every grant has ended.
    public let bonusSeconds: TimeInterval
    /// When the last running grant ends, or nil with none running.
    public let bonusEndsAt: Date?
    /// Whether this device has redeemed somebody's code. Allowed once, ever.
    public let redeemed: Bool
    public let invitesEarned: Int
    public let invitesMax: Int

    public init(
        code: String,
        bonusSeconds: TimeInterval,
        bonusEndsAt: Date?,
        redeemed: Bool,
        invitesEarned: Int,
        invitesMax: Int
    ) {
        self.code = code
        self.bonusSeconds = bonusSeconds
        self.bonusEndsAt = bonusEndsAt
        self.redeemed = redeemed
        self.invitesEarned = invitesEarned
        self.invitesMax = invitesMax
    }
}

extension RelaySignallingConnection {
    /// Both requests are signed with the device key: the bonus belongs to the key, so a made-up ID earns nothing.
    public static func referralStatus(
        at url: URL,
        clientID: String,
        identity: SelfSignedIdentity
    ) async throws -> RelayReferral {
        let proof = try RelayDeviceProof.makeReferralStatusProof(clientID: clientID, identity: identity)
        return try await referralExchange(at: url, .referralStatus(clientID: clientID, proof: proof))
    }

    public static func redeemReferral(
        at url: URL,
        clientID: String,
        code: String,
        identity: SelfSignedIdentity
    ) async throws -> RelayReferral {
        let proof = try RelayDeviceProof.makeRedeemReferralProof(clientID: clientID, code: code, identity: identity)
        return try await referralExchange(at: url, .redeemReferral(clientID: clientID, code: code, proof: proof))
    }

    private static func referralExchange(at url: URL, _ request: RelayClientMessage) async throws -> RelayReferral {
        let connection = RelaySignallingConnection(url: url)
        return try await withTaskCancellationHandler {
            defer { connection.cancel() }
            try await connection.send(request)
            while true {
                try Task.checkCancellation()
                switch try await connection.receive() {
                case .referral(let referral): return referral
                case .error(let code, let message): throw RelaySignallingError.refused(code: code, message: message)
                default: continue
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}
