public struct DeferredVideoKeyframe: Sendable {
    public struct Replay: Sendable, Equatable {
        public let frame: EncodedVideoFrame
        /// Deltas came after the keyframe and were not kept, so frames decoded on top of it would build on pictures the decoder never saw: the screen froze on the keyframe until the next periodic one.
        public let missedLaterFrames: Bool
    }

    private var frame: EncodedVideoFrame?
    private var missedLaterFrames = false

    public init() {}

    public mutating func record(_ frame: EncodedVideoFrame) {
        guard frame.isKeyframe else {
            if self.frame != nil { missedLaterFrames = true }
            return
        }
        self.frame = frame
        missedLaterFrames = false
    }

    public mutating func take() -> Replay? {
        defer { reset() }
        return frame.map { Replay(frame: $0, missedLaterFrames: missedLaterFrames) }
    }

    public func latest(matching config: VideoStreamConfig) -> EncodedVideoFrame? {
        guard frame?.pixelWidth == config.pixelWidth, frame?.pixelHeight == config.pixelHeight else {
            return nil
        }
        return frame
    }

    /// A new stream has different parameter sets, so an older keyframe cannot start it.
    public mutating func reset() {
        frame = nil
        missedLaterFrames = false
    }
}
