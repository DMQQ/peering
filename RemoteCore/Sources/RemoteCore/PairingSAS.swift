// CryptoKit on Apple platforms, swift-crypto's `Crypto` elsewhere: same API.
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Hashing the server's identity key to six digits is broken by an active MITM that grinds its own long-term key offline. The commitment exchange binds an ephemeral instead, committed before the attacker learns the other side's contribution:
///
/// ```
/// C→S  pairingCommit   SHA256(domain ‖ clientEphemeral ‖ clientNonce)
/// S→C  pairingCommit   SHA256(domain ‖ serverEphemeral ‖ serverNonce)
/// C→S  pairingReveal   clientEphemeral, clientNonce
/// S→C  pairingReveal   serverEphemeral, serverNonce
/// ```
///
/// Each side commits before seeing the other's reveal, so neither can steer the digits (as in ZRTP).
///
/// ``PairingTranscript/serverIdentityPublicKey`` must come from the TLS certificate the client
/// actually received (`SecTrustCopyCertificateChain` → leaf →
/// `SecKeyCopyExternalRepresentation`), never from an app-layer message, or a MITM would claim to be
/// whoever it liked.
///
/// Ephemeral keys travel at the application layer inside TLS because Network.framework does not expose TLS 1.3's own.
public enum PairingSAS {
    /// Versioned, so a future protocol change cannot be confused with this one.
    public static let commitmentDomain = "MacCast-Pairing-commit-v1"

    public static let sasDomain = "MacCast-Pairing-SAS-v1"

    /// Six, as in Bluetooth LE: an attacker gets one guess per pairing.
    public static let digitCount = 6

    public static func commitment(ephemeralPublicKey: Data, nonce: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(commitmentDomain.utf8))
        hasher.update(data: ephemeralPublicKey)
        hasher.update(data: nonce)
        return Data(hasher.finalize())
    }

    public static func verify(
        commitment: Data,
        ephemeralPublicKey: Data,
        nonce: Data
    ) -> Bool {
        ConstantTime.equals(commitment, self.commitment(ephemeralPublicKey: ephemeralPublicKey, nonce: nonce))
    }

    public static func code(for transcript: PairingTranscript) -> String {
        let digest = Array(SHA256.hash(data: transcript.serialized()))

        // First four digest bytes folded into 32 bits then reduced; modulo bias is far below the code's own 10⁻⁶.
        // Separate statements on purpose: as one expression the type checker gives up.
        let byte0 = UInt32(digest[0]) << 24
        let byte1 = UInt32(digest[1]) << 16
        let byte2 = UInt32(digest[2]) << 8
        let byte3 = UInt32(digest[3])
        let value: UInt32 = byte0 | byte1 | byte2 | byte3

        let code: UInt32 = value % 1_000_000
        return String(format: "%06u", code)
    }
}

/// Every exchanged field is covered: omitting one lets an attacker vary it without disturbing the digits.
public struct PairingTranscript: Sendable, Equatable {
    public var protocolVersion: UInt16
    public var clientID: String
    public var serverID: String
    public var clientEphemeralPublicKey: Data
    public var serverEphemeralPublicKey: Data
    public var clientNonce: Data
    public var serverNonce: Data
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

    /// The length prefixes are load-bearing: without them an attacker can shift bytes across a field boundary and get identical digits from different splits.
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
