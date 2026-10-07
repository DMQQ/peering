import CryptoKit
import Crypto
import Foundation
import Network
import Security

/// One of these per lane. Two lanes carry video at once while the client is in fallback, the
/// datagram lane and the control channel; they interleave on the wire and their chunk numbering is
/// independent, so a reassembler shared between them would read the other lane's chunks as a newer
/// picture and abandon the one it was assembling.
public struct VideoDatagramOpener {
    private let key: SymmetricKey
    private var window = VideoReplayWindow()
    private var chunks = VideoChunkReassembler()

    public init(key: SymmetricKey) {
        self.key = key
    }

    public mutating func open(_ datagram: Data) throws -> Frame? {
        guard datagram.count >= VideoDatagram.minForwardedSize else {
            throw VideoDatagramError.truncated(have: datagram.count, need: VideoDatagram.minForwardedSize)
        }
        // A datagram is at most a path MTU in this protocol, so one that claims otherwise came from
        // something that is not a peer running it. Refused before any of it is parsed.
        guard datagram.count <= VideoDatagram.maxDatagramSize else {
            throw VideoDatagramError.oversized(bytes: datagram.count)
        }

        // Normalised because the caller's data may be a slice of a receive buffer, and every
        // offset below is read from the start of the datagram rather than from its storage.
        let body = Data(datagram)
        let counter = body.readBigEndianUInt64(at: 0)
        guard window.accepts(counter) else { return nil }

        let tagStart = body.count - VideoDatagram.tagSize
        guard let nonce = VideoDatagramSealer.nonce(counter),
              let box = try? ChaChaPoly.SealedBox(
                  nonce: nonce,
                  ciphertext: body[VideoDatagram.counterSize..<tagStart],
                  tag: body[tagStart...]
              ),
              let plaintext = try? ChaChaPoly.open(box, using: key)
        else {
            throw VideoDatagramError.authenticationFailed
        }

        window.commit(counter)

        var decoder = FrameDecoder()
        decoder.append(plaintext)
        guard let decoded = try? decoder.next() else {
            throw VideoDatagramError.malformedPayload
        }

        guard decoded.kind == .videoChunk else { return decoded }
        do {
            return try chunks.ingest(decoded)
        } catch {
            throw VideoDatagramError.malformedPayload
        }
    }

    public mutating func reset() {
        window.reset()
        chunks = VideoChunkReassembler()
    }
}
