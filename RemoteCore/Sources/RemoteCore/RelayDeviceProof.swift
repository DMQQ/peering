import Foundation

/// A device ID is public (Bonjour TXT, pairing QR), so registering one requires a signature by the device's long-term P-256 key.
public struct RelayDeviceProof: Sendable, Equatable {
    /// Hex of the 65-byte uncompressed P-256 point, `0x04 ‖ X ‖ Y`.
    public let publicKey: String
    public let signature: String
    public let proofTime: UInt64

    public init(publicKey: String, signature: String, proofTime: UInt64) {
        self.publicKey = publicKey
        self.signature = signature
        self.proofTime = proofTime
    }

    /// Mirrors `device_proof::payload` in the relay. Newline-separated; no UUID or integer holds a newline, so inputs cannot collide.
    public static func payload(deviceID: String, proofTime: UInt64) -> Data {
        Data("peeringd-host-registration-v1\n\(deviceID)\n\(proofTime)".utf8)
    }

    public static func make(
        deviceID: String,
        identity: SelfSignedIdentity,
        now: Date = Date()
    ) throws -> RelayDeviceProof {
        try make(identity: identity, over: payload(deviceID: deviceID, proofTime: stamp(now)), now: now)
    }

    /// Mirrors `device_proof::client_payload`. A separate domain: a client signature must not be accepted as a host registration.
    public static func clientPayload(clientID: String, proofTime: UInt64) -> Data {
        Data("peeringd-client-registration-v1\n\(clientID)\n\(proofTime)".utf8)
    }

    /// Keyed on the Keychain key so relay metering survives a reinstall (the client ID resets).
    public static func makeClientProof(
        clientID: String,
        identity: SelfSignedIdentity,
        now: Date = Date()
    ) throws -> RelayDeviceProof {
        try make(identity: identity, over: clientPayload(clientID: clientID, proofTime: stamp(now)), now: now)
    }

    /// Clamped at zero rather than trapping on a pre-1970 clock.
    private static func stamp(_ now: Date) -> UInt64 {
        UInt64(max(0, now.timeIntervalSince1970))
    }

    private static func make(
        identity: SelfSignedIdentity,
        over message: Data,
        now: Date
    ) throws -> RelayDeviceProof {
        RelayDeviceProof(
            publicKey: hex(identity.publicKeyBytes),
            signature: hex(try identity.signature(for: message)),
            proofTime: stamp(now)
        )
    }

    /// `%02x`: a dropped leading zero shortens the string and the relay rejects it on length.
    private static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
