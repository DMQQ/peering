import CryptoKit
import Crypto
import Foundation
import Network
import Security

/// 1024-byte chunks rather than the control channel's 16 KB, because a datagram is one packet: a
/// 16 KB chunk would be eleven fragments on a 1500-byte path and would lose the whole picture to
/// any one of them. At ``VideoChunk/maxDatagramPayload`` a sealed datagram is about 1080 bytes,
/// which stays under the 1280-byte minimum MTU of IPv6. The chunking is ``VideoChunkEncoder``'s, so
public struct VideoDatagramSealer: Sendable {
    private let key: SymmetricKey
    private let token: Data
    private var counter: UInt64 = 0
    private var frameID: UInt32 = 0

    public init(key: SymmetricKey, token: Data) throws {
        guard token.count == VideoDatagram.tokenSize else {
            throw VideoDatagramError.invalidToken(bytes: token.count)
        }
        self.key = key
        self.token = token
    }

    public mutating func seal(kind: MessageKind, payload: Data) -> [Data] {
        frameID &+= 1
        let pieces = VideoChunkEncoder.encode(
            kind: kind,
            payload: payload,
            frameID: frameID,
            chunkSize: VideoChunk.maxDatagramPayload
        )

        var datagrams: [Data] = []
        datagrams.reserveCapacity(pieces.count)
        for piece in pieces {
            let next = counter &+ 1
            guard let nonce = Self.nonce(next),
                  let box = try? ChaChaPoly.seal(FrameEncoder.encode(piece), using: key, nonce: nonce)
            else { return [] }
            counter = next

            var datagram = Data(capacity: token.count + VideoDatagram.counterSize + box.ciphertext.count + VideoDatagram.tagSize)
            datagram.append(token)
            datagram.appendBigEndian(next)
            datagram.append(box.ciphertext)
            datagram.append(box.tag)
            datagrams.append(datagram)
        }
        return datagrams
    }

    /// The 12 bytes ChaChaPoly wants, built from the 8 the wire carries: four leading zeros and the
    /// counter, big-endian. The counter is the whole of the nonce's entropy and never repeats under
    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce? {
        var bytes = Data([0, 0, 0, 0])
        bytes.appendBigEndian(counter)
        return try? ChaChaPoly.Nonce(data: bytes)
    }
}
