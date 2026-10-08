import CoreMedia
import Foundation
import RemoteCore

extension VideoCodec {
/// This codec as the wire spells it.
    var wireCodec: RemoteCore.VideoCodec {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }
}

/// Bridges the capture side's frames onto the wire format.
final class CaptureFrameAdapter: @unchecked Sendable {
    private let lock = NSLock()
    private var _config: VideoStreamConfig?

    var config: VideoStreamConfig? { lock.withLock { _config } }

    /// Forgets the description, because the source it describes is no longer the one being captured.
    func forget() {
        lock.withLock { _config = nil }
    }

    struct Prepared {
        let frame: EncodedVideoFrame
        let config: VideoStreamConfig?
        let hadConfig: Bool
    }

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
