import Foundation

/// A device's proof that it is the device whose ID it is registering.
///
/// **The problem this answers.** A device ID is a name. `DeviceIdentity` says so itself, and the
/// ID is broadcast in the Mac's Bonjour TXT record to everyone on the network and printed into the
/// pairing QR code. That was fine while the ID was only how two devices found each other, and it
/// stopped being fine when the relay started writing it into a table: anyone who learned an ID
/// could register it, take the entry away from the Mac that owns it, and leave that Mac unreachable
/// through the relay. The relay now refuses a registration that cannot prove itself, and this is
/// the proof.
///
/// **A signature, not a shared secret**, because every device already has the key to make one. The
/// identity below is the same long-term P-256 key the pairing handshake pins, so there is nothing
/// new to mint, nothing new to store, and no new way to lose access: a device that has lost this
/// key cannot pair either.
///
/// **The payload is built here and nowhere else**, and the relay builds the same string from its
/// own side. Two ends independently composing "what was signed" is the classic way a signature
/// scheme fails for reasons nobody can see, so both spellings are pinned by a test to the same
/// literal, and the version tag means a later scheme is a different string rather than a silently
/// incompatible one.
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
    /// Newline-separated in a fixed order, with a version tag first. A device ID is a UUID and a
    /// time is a decimal integer, so neither can contain a newline and no two distinct inputs can
    /// produce the same string, which is why the delimiter is one that cannot appear in the data
    /// rather than one that has to be escaped out of it.
    public static func payload(deviceID: String, proofTime: UInt64) -> Data {
        Data("peeringd-host-registration-v1\n\(deviceID)\n\(proofTime)".utf8)
    }

    /// Signs a host registration with this device's identity.
    ///
    /// `now` is a parameter rather than read here so that a test can pin the string it produces,
    /// which is the only way the two ends' spellings can be compared at all.
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
    /// **A second domain rather than the same one**, and the separator in the tag is the whole of
    /// the reason. A device signs both of these with the same key, and a client signing
    /// `peeringd-host-registration-v1\n...` must not produce something a relay would accept as a
    /// host registration for the same ID, or the two proofs would be interchangeable and one of
    /// them would be worth less than it looks.
    public static func clientPayload(clientID: String, proofTime: UInt64) -> Data {
        Data("peeringd-client-registration-v1\n\(clientID)\n\(proofTime)".utf8)
    }

    /// Signs a session request with this device's identity.
    ///
    /// **What this is for, because it is not about the plan.** The relay meters relay time against
    /// the client ID a phone announces, and that ID lives in the app's own storage: deleting and
    /// reinstalling the app mints a new one and hands out the free allowance again. The key does
    /// not move, because it is in the Keychain and iOS keeps those. So a phone that signs here is
    /// metered under a key that survives a reinstall, and the announced ID becomes a name in a log
    /// line rather than the thing an allowance hangs from.
    ///
    /// It is not a proof of anything else: the same key is pinned on the Mac, which is what decides
    /// whether a session may be driven, and this changes nothing about that.
    public static func makeClientProof(
        clientID: String,
        identity: SelfSignedIdentity,
        now: Date = Date()
    ) throws -> RelayDeviceProof {
        try make(identity: identity, over: clientPayload(clientID: clientID, proofTime: stamp(now)), now: now)
    }

    /// The seconds a signature covers, from the caller's clock.
    ///
    /// Clamped at zero rather than allowed to trap: a device whose clock is set before 1970 is a
    /// device with a broken clock, and the relay refuses a stale proof with a sentence rather than
    /// a crash on this end.
    private static func stamp(_ now: Date) -> UInt64 {
        UInt64(max(0, now.timeIntervalSince1970))
    }

    /// Signs one of the two payloads with this device's identity.
    ///
    /// The one place a proof is built, so that both of them are the same shape: hex of the key, hex
    /// of the DER signature, and the time the signature covers.
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

    /// Lowercase hex, and the general form of the encoder the video token already had.
    ///
    /// `%02x` rather than a shorter spelling because a dropped leading zero is the only way to get
    /// this wrong: it shortens the string by one character without changing any of the others, and
    /// the relay would refuse the result for a reason that reads as a length problem.
    private static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
