import CoreMedia
import Foundation
import RemoteCore

extension VideoCodec {
    /// This codec as the wire spells it.
    ///
    /// There are two `VideoCodec` types and the split is deliberate: this one carries the
    /// VideoToolbox settings (`CMVideoCodecType`, profile level), and the shared module's
    /// cannot mention those without dragging CoreMedia into a target the iOS client links —
    /// the same mistake that made the original `RemoteCommand` fail to build for iOS.
    ///
    /// The switch is exhaustive rather than `default`-ed, and that is the point of writing it
    /// out: adding a case to either enum becomes a compile error here, instead of a stream
    /// that negotiates a codec the other end cannot decode.
    var wireCodec: RemoteCore.VideoCodec {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }
}

/// Bridges the capture side's frames onto the wire format.
///
/// The two types look similar enough to be mistaken for each other, and the difference is
/// the whole reason this exists. ``EncodedFrame`` is what VideoToolbox hands back: it
/// carries a `CMTime`, a `CGSize`, and the parameter sets *when there are any*. The wire's
/// ``EncodedVideoFrame`` is deliberately free of CoreMedia and CoreGraphics — that is what
/// keeps `RemoteCore` buildable for iOS — so every value has to be converted, not passed.
///
/// **The awkward part is that parameter sets only exist on keyframes.** They live in the
/// format description attached to the sample buffer, and VideoToolbox emits that alongside
/// the first frame of a session rather than at session creation. So a stream description
/// cannot be built when capture starts; it becomes available part-way through, and the
/// client cannot decode anything until it arrives. This type is where that fact is
/// contained: it holds the most recent description it has seen and reports when a frame has
/// changed it.
///
/// Locked, and not because frames are expected to race. ``CapturePipeline`` rebuilds the
/// encoder when the captured surface changes size, and the old session is torn down *after*
/// the replacement is installed — so for a moment two VideoToolbox threads can both be
/// delivering into here, and an unlocked `config` would be a genuine race rather than a
/// theoretical one.
final class CaptureFrameAdapter: @unchecked Sendable {
    private let lock = NSLock()
    private var _config: VideoStreamConfig?

    /// The stream as last described, or `nil` if no keyframe has been seen yet.
    ///
    /// Nil is not an error state and not a reason to refuse a client. It means "the encoder
    /// has not produced its first frame", which is exactly the state a client connecting to
    /// a freshly started capture arrives in.
    var config: VideoStreamConfig? { lock.withLock { _config } }

    struct Prepared {
        let frame: EncodedVideoFrame
        /// The description to send **before** ``frame``, when this frame is what established
        /// or changed it. `nil` means the description is unchanged and the client already has
        /// it — sending it again would be harmless but would also re-initialise a decoder
        /// that is working fine.
        let config: VideoStreamConfig?
        /// Whether a description existed before this frame. A first-time attach and a
        /// mid-stream description change need different calls on the streamer, and they are
        /// indistinguishable from the config alone.
        let hadConfig: Bool
    }

    /// Converts a frame, and reports whether it changed the stream's description.
    func adopt(_ frame: EncodedFrame) -> Prepared {
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

        // The rule itself lives in `RemoteCore` so it can be unit-tested — see
        // `VideoStreamConfig.updated(from:codec:pixelWidth:pixelHeight:parameterSets:)`.
        // It is the difference between a client that starts decoding and one that stares at
        // a black screen, and it is not something this layer should be re-deriving.
        let updated = VideoStreamConfig.updated(
            from: previous,
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
