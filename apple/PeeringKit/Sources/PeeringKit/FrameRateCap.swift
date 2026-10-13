import Foundation

/// Thins a stream of frames to at most a requested rate, by timestamp.
///
/// Pure: the capture clock's seconds go in, a yes or no comes out. A frame is kept when at least 80% of the interval has passed since the last kept one, so a capture clock with jitter does not alternate between keeping and dropping at a cap near the capture rate.
public struct FrameRateCap: Sendable, Equatable {
    private static let slack = 0.8

    public private(set) var limit: Int?
    private var lastKept: Double?

    public init(limit: Int? = nil) {
        self.limit = limit
    }

    /// Nil, zero or negative lifts the cap.
    public mutating func setLimit(_ framesPerSecond: Int?) {
        limit = framesPerSecond.flatMap { $0 > 0 ? $0 : nil }
    }

    public mutating func admits(at seconds: Double) -> Bool {
        let keeps = shouldKeep(seconds)
        if keeps { lastKept = seconds }
        return keeps
    }

    private func shouldKeep(_ seconds: Double) -> Bool {
        guard let limit, let lastKept else { return true }
        // A clock that went backwards (a restarted stream) is a new run, not a frame to wait out.
        guard seconds >= lastKept else { return true }
        return seconds - lastKept >= Self.slack / Double(limit)
    }
}
