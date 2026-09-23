// CryptoKit is the system framework on Apple platforms; the open-source swift-crypto module is
// named `Crypto`. Same API either way, so the package stays dependency-free on Apple platforms
// without giving up portability.
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Namespace for the short-authentication-string (SAS) pairing exchange.
///
/// Hashing the server's identity key and showing six digits is broken against an active
/// man-in-the-middle, which controls its own long-term key and can grind it offline until it hashes
/// to the digits the Mac will display. The commitment exchange below binds an ephemeral instead, one
/// the attacker must commit to before it learns what the other side contributed:
///
/// ```
/// C→S  pairingCommit   SHA256(domain ‖ clientEphemeral ‖ clientNonce)
/// S→C  pairingCommit   SHA256(domain ‖ serverEphemeral ‖ serverNonce)
/// C→S  pairingReveal   clientEphemeral, clientNonce
/// S→C  pairingReveal   serverEphemeral, serverNonce
/// ```
///
/// Each side commits before it has seen the other's reveal, so neither can choose its contribution
/// to steer the digits, and an attacker in the middle must pick its ephemeral before the real server
/// reveals its own. Same reasoning as ZRTP's commitment scheme.
///
/// ``PairingTranscript/serverIdentityPublicKey`` must come from the TLS certificate the client
/// actually received (`SecTrustCopyCertificateChain` → leaf →
/// `SecKeyCopyExternalRepresentation`), never from an app-layer message, or a MITM would claim to be
/// whoever it liked.
///
/// The ephemeral keys are exchanged at the application layer inside the TLS session, because
/// Network.framework does not expose TLS 1.3's own ephemeral keys; TLS already protects them.
public enum PairingSAS {
    /// Domain separator for the commitment hash. Versioned, so a future protocol change cannot be
    /// confused with this one.
    public static let commitmentDomain = "MacCast-Pairing-commit-v1"

    /// Domain separator for the final SAS derivation.
    public static let sasDomain = "MacCast-Pairing-SAS-v1"

    /// Number of decimal digits shown to the user. Six is the Bluetooth LE figure: an attacker gets
    /// one guess per pairing.
    public static let digitCount = 6

    /// Commits to an ephemeral public key without revealing it.
    public static func commitment(ephemeralPublicKey: Data, nonce: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(commitmentDomain.utf8))
        hasher.update(data: ephemeralPublicKey)
        hasher.update(data: nonce)
        return Data(hasher.finalize())
    }

    /// Checks a reveal against the commitment received earlier.
    public static func verify(
        commitment: Data,
        ephemeralPublicKey: Data,
        nonce: Data
    ) -> Bool {
        ConstantTime.equals(commitment, self.commitment(ephemeralPublicKey: ephemeralPublicKey, nonce: nonce))
    }

    /// Derives the six-digit code both parties display.
    ///
    /// - Returns: exactly ``digitCount`` ASCII decimal digits, zero-padded.
    public static func code(for transcript: PairingTranscript) -> String {
        let digest = Array(SHA256.hash(data: transcript.serialized()))

        // Fold the first four digest bytes into a 32-bit value and reduce. Bluetooth LE uses 20 bits
        // for the same 10⁶ space; the modulo bias at 32 bits is ~2⁻¹² of a code, far below the 10⁻⁶
        // the code itself has. Written as separate statements on purpose: as one expression the type
        // checker gives up on it ("unable to type-check in reasonable time").
        let byte0 = UInt32(digest[0]) << 24
        let byte1 = UInt32(digest[1]) << 16
        let byte2 = UInt32(digest[2]) << 8
        let byte3 = UInt32(digest[3])
        let value: UInt32 = byte0 | byte1 | byte2 | byte3

        let code: UInt32 = value % 1_000_000
        return String(format: "%06u", code)
    }
}

/// Everything both parties bind into the pairing code, in a fixed agreed order.
///
/// Every field the peers exchanged is covered: omitting one would let an attacker vary it freely
/// without disturbing the digits.
public struct PairingTranscript: Sendable, Equatable {
    public var protocolVersion: UInt16
    public var clientID: String
    public var serverID: String
    public var clientEphemeralPublicKey: Data
    public var serverEphemeralPublicKey: Data
    public var clientNonce: Data
    public var serverNonce: Data
    /// The host's long-term identity key, as seen in the TLS certificate by the client.
    public var serverIdentityPublicKey: Data

    public init(
        protocolVersion: UInt16,
        clientID: String,
        serverID: String,
        clientEphemeralPublicKey: Data,
        serverEphemeralPublicKey: Data,
        clientNonce: Data,
        serverNonce: Data,
        serverIdentityPublicKey: Data
    ) {
        self.protocolVersion = protocolVersion
        self.clientID = clientID
        self.serverID = serverID
        self.clientEphemeralPublicKey = clientEphemeralPublicKey
        self.serverEphemeralPublicKey = serverEphemeralPublicKey
        self.clientNonce = clientNonce
        self.serverNonce = serverNonce
        self.serverIdentityPublicKey = serverIdentityPublicKey
    }

    /// Canonical serialization: every field length-prefixed with a big-endian `u32`.
    ///
    /// The length prefixes are load-bearing rather than tidiness: concatenating variable-length
    /// fields without them lets an attacker shift bytes across a boundary so two different field
    /// splits produce identical bytes, and therefore identical digits, while the two sides disagree
    /// about what they hashed.
    public func serialized() -> Data {
        var out = Data()
        func put(_ data: Data) {
            let count = UInt32(data.count)
            out.append(UInt8(truncatingIfNeeded: count >> 24))
            out.append(UInt8(truncatingIfNeeded: count >> 16))
            out.append(UInt8(truncatingIfNeeded: count >> 8))
            out.append(UInt8(truncatingIfNeeded: count))
            out.append(data)
        }

        put(Data(PairingSAS.sasDomain.utf8))
        put(withUnsafeBytes(of: protocolVersion.bigEndian) { Data($0) })
        put(Data(clientID.utf8))
        put(Data(serverID.utf8))
        put(clientEphemeralPublicKey)
        put(serverEphemeralPublicKey)
        put(clientNonce)
        put(serverNonce)
        put(serverIdentityPublicKey)
        return out
    }
}
