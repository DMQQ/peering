import CryptoKit
import Crypto
import Foundation
import Network
import Security

public enum VideoDatagramDirection: Sendable, Equatable, CaseIterable {
    case clientToHost
    case hostToClient
}

/// Two keys rather than one because the counter is the AEAD nonce and it travels in the clear, so a
/// nonce may never repeat under a key: both ends counting from one under a single key would repeat
/// it on the first datagram of each direction. HKDF's `info` separates them, and the labels are
/// spelled out here so the two ends cannot drift into two derivations that both look correct.
public struct VideoKeySchedule: Sendable {
    public static let secretSize = 32

    private static let salt = Data("pl.dmq.peering.video-datagram".utf8)

    private static let clientToHostLabel = "video client-to-host"
    private static let hostToClientLabel = "video host-to-client"

    private let secret: Data

    public init(secret: Data) {
        self.secret = secret
    }

    public static func randomSecret() -> Data? {
        var bytes = [UInt8](repeating: 0, count: secretSize)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return Data(bytes)
    }

    public func key(for direction: VideoDatagramDirection) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Self.salt,
            info: Data(Self.label(for: direction).utf8),
            outputByteCount: Self.secretSize
        )
    }

    private static func label(for direction: VideoDatagramDirection) -> String {
        switch direction {
        case .clientToHost: return clientToHostLabel
        case .hostToClient: return hostToClientLabel
        }
    }

    public func sealer(
        token: Data,
        direction: VideoDatagramDirection
    ) throws -> VideoDatagramSealer {
        try VideoDatagramSealer(key: key(for: direction), token: token)
    }

    public func opener(direction: VideoDatagramDirection) -> VideoDatagramOpener {
        VideoDatagramOpener(key: key(for: direction))
    }
}

public struct VideoKeyGrant: Codable, Sendable, Equatable {
    public let secret: Data

    public init(secret: Data) {
        self.secret = secret
    }
}
