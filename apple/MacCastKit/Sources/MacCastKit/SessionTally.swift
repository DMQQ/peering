import Foundation

/// What one session added up to across the drops it was put back from, for the single `session_ended` event that closes it.
public struct SessionTally: Sendable, Equatable {
    public private(set) var seconds = 0
    public private(set) var videoBytes: Int64 = 0
    public private(set) var droppedFrames = 0
    public private(set) var reconnects = 0

    public init() {}

    /// One connected stretch, closed by a drop or by the end.
    public mutating func addStretch(seconds: TimeInterval, videoBytes: Int64, droppedFrames: Int) {
        self.seconds += max(0, Int(seconds.rounded()))
        self.videoBytes += max(0, videoBytes)
        self.droppedFrames += max(0, droppedFrames)
    }

    public mutating func noteReconnect() {
        reconnects += 1
    }
}
