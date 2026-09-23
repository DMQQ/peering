import Foundation

/// A device's proof that it is the device whose ID it is registering.
///
/// A device ID is a name: broadcast in the Mac's Bonjour TXT record to everyone on the network and
/// printed into the pairing QR code, so anyone who learned one could register it, take the entry
/// away from the Mac that owns it and leave that Mac unreachable through the relay.
///
/// A signature rather than a shared secret, because every device already has the key: the identity
/// below is the same long-term P-256 key the pairing handshake pins, so there is nothing new to
/// mint and no new way to lose access.
///
/// The payload is built here and nowhere else, and the relay builds the same string from its own
/// side. Both spellings are pinned by a test to the same literal, and the version tag makes a later
/// scheme a different string rather than a silently incompatible one.
public struct RelayDeviceProof: Sendable, Equatable {
    /// Hex of the 65-byte uncompressed P-256 point, `0x04 ‖ X ‖ Y`.
    public let publicKey: String
    /// Hex of the DER-encoded ECDSA signature over ``payload(deviceID:proofTime:)``.
    public let signature: String
    /// Seconds since the Unix epoch, covered by the signature.
    public let proofTime: UInt64

    public init(publicKey: String, signature: String, proofTime: UInt64) {
        self.publicKey = publicKey
        self.signature = signature
        self.proofTime = proofTime
    }

    /// The bytes a device signs to register. Mirrors `device_proof::payload` in the relay.
    ///
    /// Newline-separated in a fixed order, with a version tag first. Neither a UUID nor a decimal
    /// integer can contain a newline, so no two distinct inputs produce the same string.
    public static func payload(deviceID: String, proofTime: UInt64) -> Data {
        Data("peeringd-host-registration-v1\n\(deviceID)\n\(proofTime)".utf8)
    }

    /// Signs a host registration with this device's identity.
    ///
    /// `now` is a parameter rather than read here, so a test can pin the string it produces.
    public static func make(
        deviceID: String,
        identity: SelfSignedIdentity,
        now: Date = Date()
    ) throws -> RelayDeviceProof {
        try make(identity: identity, over: payload(deviceID: deviceID, proofTime: stamp(now)), now: now)
    }

    /// The bytes a phone signs to be metered under its own key rather than under its ID.
    /// Mirrors `device_proof::client_payload` in the relay.
    ///
    /// A second domain rather than the same one, because a device signs both payloads with the
    /// same key: a client signature must not be acceptable as a host registration for the same ID.
    public static func clientPayload(clientID: String, proofTime: UInt64) -> Data {
        Data("peeringd-client-registration-v1\n\(clientID)\n\(proofTime)".utf8)
    }

    /// Signs a session request with this device's identity.
    ///
    /// The relay meters relay time against the client ID a phone announces, and that ID lives in
    /// the app's own storage: reinstalling mints a new one and hands out the free allowance again.
    /// The key does not move, because it is in the Keychain and iOS keeps those, so a phone that
    /// signs here is metered under a key that survives a reinstall.
    ///
    /// Not a proof of anything else: the same key is pinned on the Mac, which is what decides
    /// whether a session may be driven.
    public static func makeClientProof(
        clientID: String,
        identity: SelfSignedIdentity,
        now: Date = Date()
    ) throws -> RelayDeviceProof {
        try make(identity: identity, over: clientPayload(clientID: clientID, proofTime: stamp(now)), now: now)
    }

    /// The seconds a signature covers, from the caller's clock. Clamped at zero rather than allowed
    /// to trap: a device whose clock is set before 1970 is a device with a broken clock.
    private static func stamp(_ now: Date) -> UInt64 {
        UInt64(max(0, now.timeIntervalSince1970))
    }

    /// Signs one of the two payloads with this device's identity. The one place a proof is built:
    /// hex of the key, hex of the DER signature, and the time the signature covers.
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

    /// Lowercase hex. `%02x` rather than a shorter spelling: a dropped leading zero shortens the
    /// string by one character without changing the others, and the relay refuses the result as a
    /// length problem.
    private static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
