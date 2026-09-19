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

    /// Signs a registration with this device's identity.
    ///
    /// `now` is a parameter rather than read here so that a test can pin the string it produces,
    /// which is the only way the two ends' spellings can be compared at all.
    public static func make(
        deviceID: String,
        identity: SelfSignedIdentity,
        now: Date = Date()
    ) throws -> RelayDeviceProof {
        let proofTime = UInt64(max(0, now.timeIntervalSince1970))
        let message = payload(deviceID: deviceID, proofTime: proofTime)
        let signature = try identity.signature(for: message)

        return RelayDeviceProof(
            publicKey: hex(identity.publicKeyBytes),
            signature: hex(signature),
            proofTime: proofTime
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
