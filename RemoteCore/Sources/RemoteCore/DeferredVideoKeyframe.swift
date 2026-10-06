/// The client holds a keyframe that beat the display layer; the host holds the last keyframe for a
/// newly attached client, because a still ScreenCaptureKit stream may produce no fresh frame.
public struct DeferredVideoKeyframe: Sendable {
    private var frame: EncodedVideoFrame?

    public init() {}

    public mutating func record(_ frame: EncodedVideoFrame) {
        guard frame.isKeyframe else { return }
        self.frame = frame
    }

    public mutating func take() -> EncodedVideoFrame? {
        defer { frame = nil }
        return frame
    }

    public func latest(matching config: VideoStreamConfig) -> EncodedVideoFrame? {
        guard frame?.pixelWidth == config.pixelWidth, frame?.pixelHeight == config.pixelHeight else {
            return nil
        }
        return frame
    }

    /// A new stream has different parameter sets, so an older keyframe cannot start it.
    public mutating func reset() { frame = nil }
}
