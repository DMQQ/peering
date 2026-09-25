import CoreMedia
import Foundation
import RemoteCore

extension VideoCodec {
/// This codec as the wire spells it.
///
/// There are two `VideoCodec` types: this one carries the VideoToolbox settings
/// (`CMVideoCodecType`, profile level), and the shared module's cannot mention those without
/// dragging CoreMedia into a target the iOS client links.
///
/// The switch is exhaustive rather than `default`-ed: adding a case to either enum becomes a
/// compile error here, instead of a stream that negotiates a codec the other end cannot decode.
    var wireCodec: RemoteCore.VideoCodec {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }
}

/// Bridges the capture side's frames onto the wire format.
///
/// ``EncodedFrame`` is what VideoToolbox hands back: a `CMTime`, a `CGSize`, and the parameter
/// sets when there are any. The wire's ``EncodedVideoFrame`` is deliberately free of CoreMedia and
/// CoreGraphics, which is what keeps `RemoteCore` buildable for iOS, so every value is converted
/// rather than passed.
///
/// Parameter sets exist only on keyframes. They live in the format description attached to the
/// sample buffer, and VideoToolbox emits that alongside the first frame of a session rather than
/// at session creation, so a stream description cannot be built when capture starts and the
/// client cannot decode until it arrives. This type holds the most recent description it has
/// seen and reports when a frame has changed it.
///
/// Locked because ``CapturePipeline`` tears the old encoder down after the replacement is
/// installed when the captured surface changes size, so for a moment two VideoToolbox threads
/// can both be delivering into here.
final class CaptureFrameAdapter: @unchecked Sendable {
    private let lock = NSLock()
    private var _config: VideoStreamConfig?

/// The stream as last described, or `nil` if no keyframe has been seen yet.
///
/// Nil is not an error state and not a reason to refuse a client: it means the encoder has not
/// produced its first frame yet, which is the state a client connecting to a fresh capture
/// arrives in.
    var config: VideoStreamConfig? { lock.withLock { _config } }

    /// Forgets the description, because the source it describes is no longer the one being captured.
    ///
    /// **A description outlives the stream that produced it, and it is now the picture's identity.**
    /// It is handed to a client that attaches before the new stream has produced a frame — a
    /// reconnect, or a client arriving while the capture was switching or stopping — and that client
    /// would then name, title and measure a picture the Mac is not sending. The new stream's own
    /// first keyframe re-establishes it, so nothing is lost by dropping it. See
    /// ``VideoCoordinator/serve(_:)``.
    func forget() {
        lock.withLock { _config = nil }
    }

    struct Prepared {
        let frame: EncodedVideoFrame
/// The description to send before ``frame``, when this frame is what established or changed it.
/// `nil` means the client already has it, and sending it again would re-initialise a decoder
/// that is working fine.
        let config: VideoStreamConfig?
/// Whether a description existed before this frame. A first-time attach and a mid-stream change
/// need different calls on the streamer, and they are indistinguishable from the config alone.
        let hadConfig: Bool
    }

    /// Converts a frame, and reports whether it changed the stream's description.
    func adopt(_ frame: EncodedFrame, sourceID: String) -> Prepared {
        let wire = EncodedVideoFrame(
            isKeyframe: frame.isKeyframe,
            pixelWidth: Int(frame.pixelSize.width.rounded()),
            pixelHeight: Int(frame.pixelSize.height.rounded()),
            presentationTime: VideoTimestamp(
                value: frame.presentationTime.value,
                timescale: Int32(clamping: frame.presentationTime.timescale)
            ),
            data: frame.data
        )

        lock.lock()
        let previous = _config

// The rule lives in `RemoteCore` so it can be unit-tested. It is the difference between a
// client that starts decoding and one that stares at a black screen.
        let updated = VideoStreamConfig.updated(
            from: previous,
            sourceID: sourceID,
            codec: frame.codec.wireCodec,
            pixelWidth: wire.pixelWidth,
            pixelHeight: wire.pixelHeight,
            parameterSets: frame.parameterSets
        )
        if let updated { _config = updated }
        lock.unlock()

        return Prepared(frame: wire, config: updated, hadConfig: previous != nil)
    }
}
