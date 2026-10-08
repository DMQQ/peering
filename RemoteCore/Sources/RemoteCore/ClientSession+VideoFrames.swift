import CryptoKit
import Crypto
import Foundation
import Network
import Security
import os

extension ClientSession {
    /// One piece of a clipboard payload; a malformed piece costs the payload and nothing else. `transport` matters: a picture on the preferred transport during fallback is the only evidence the path works again. See ``VideoFallbackPolicy/notePrimaryPicture()``.
    func handleClipboardChunk(_ frame: Frame) {
        let reassembled = lock.withLock { () -> Frame? in
            do {
                return try clipboardChunks.ingest(frame)
            } catch {
                clientSessionLog.error(
                    "dropping a malformed clipboard chunk: \(String(describing: error), privacy: .public)"
                )
                return nil
            }
        }
        guard let reassembled else { return }
        handleClipboardContent(reassembled)
    }

    /// A whole clipboard payload, decoded leniently: a newer Mac's payload this build cannot read is ignored rather than disconnecting.
    func handleClipboardContent(_ frame: Frame) {
        guard let payload = try? MessageCodec.decode(ClipboardPayload.self, from: frame.payload) else {
            clientSessionLog.error("could not decode a clipboard payload")
            return
        }
        emit(.clipboard(payload))
    }

    func handleVideoFrame(_ frame: Frame, from transport: VideoTransport) {
        // Chunked payloads are what the fallback looks like on the wire. One level only: a chunk of a chunk is refused.
        if frame.kind == .videoChunk {
            let reassembled = lock.withLock { () -> Frame? in
                do {
                    return try videoChunks.ingest(frame)
                } catch {
                    clientSessionLog.error("dropping a malformed video chunk: \(String(describing: error), privacy: .public)")
                    return nil
                }
            }
            guard let reassembled else { return }
            handleVideoFrame(reassembled, from: transport)
            return
        }

        switch frame.kind {
        case .videoConfig:
            note(pictureOn: transport)
            guard let config = try? MessageCodec.decode(VideoStreamConfig.self, from: frame.payload) else {
                clientSessionLog.error("could not decode a video config")
                return
            }
            // The picture is back, the only thing that counts as recovery: a socket that connected and said nothing is the failure the ladder exists for, so this is not cleared where the connection opens. Preferred lane only.
            if transport == .primary {
                lock.withLock { videoReconnectLadder.reset() }
            }
            emit(.video(.config(config)))
            // A described stream is what the datagram lane waits for. See ``wantsVideoDatagrams``.
            startVideoDatagrams()

        case .videoFrame:
            note(pictureOn: transport)
            do {
                emit(.video(.frame(try EncodedVideoFrame(decoding: frame.payload))))
            } catch {
                clientSessionLog.error("dropping a malformed video frame: \(String(describing: error), privacy: .public)")
            }

        case .error:
            let payload = try? MessageCodec.decode(ErrorPayload.self, from: frame.payload)
            emit(.video(.ended(payload?.message ?? "the Mac reported an error")))

        case .audioConfig:
            if let config = try? MessageCodec.decode(AudioStreamConfig.self, from: frame.payload) {
                emit(.audio(.config(config)))
            } else {
                clientSessionLog.error("could not decode an audio config, so this stream has no sound")
            }

        case .audioFrame:
            if let frame_decoded = try? EncodedAudioFrame(decoding: frame.payload) {
                emit(.audio(.frame(frame_decoded)))
            } else {
                clientSessionLog.error("dropping a malformed audio frame")
            }

        default:
            break
        }
    }
}
