/// One bounded recovery point for video startup and reconnection.
///
/// Both ends need the same rule. The client holds a keyframe that beat the display layer and
/// consumes it when the layer attaches. The host holds the last keyframe for a newly attached
/// client because a completely still ScreenCaptureKit stream may produce no fresh frame at all.
public struct DeferredVideoKeyframe: Sendable {
    private var frame: EncodedVideoFrame?

    public init() {}

    /// Keeps only the latest recovery point. A delta is unusable without one and cannot replace it.
    public mutating func record(_ frame: EncodedVideoFrame) {
        guard frame.isKeyframe else { return }
        self.frame = frame
    }

    /// Hands the recovery point to a newly attached display exactly once.
    public mutating func take() -> EncodedVideoFrame? {
        defer { frame = nil }
        return frame
    }

    /// Reads a host-side recovery point only when its encoded dimensions match the description.
    public func latest(matching config: VideoStreamConfig) -> EncodedVideoFrame? {
        guard frame?.pixelWidth == config.pixelWidth, frame?.pixelHeight == config.pixelHeight else {
            return nil
        }
        return frame
    }

    /// A new stream has different parameter sets, so an older keyframe cannot start it.
    public mutating func reset() { frame = nil }
}
