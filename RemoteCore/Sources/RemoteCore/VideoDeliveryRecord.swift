import Foundation

/// What a session's picture went through, for the one analytics event that says whether a network let video through.
public struct VideoDeliveryRecord: Sendable, Equatable {
    public private(set) var transport: VideoTransport = .primary
    /// Sticky: the session returning to the datagram lane afterwards does not make it a session that never needed the fallback.
    public private(set) var fellBack = false
    private var readyAt: TimeInterval?
    private var firstPictureAt: TimeInterval?

    public init(readyAt: TimeInterval? = nil) {
        self.readyAt = readyAt
    }

    public mutating func notePicture(at now: TimeInterval) {
        if firstPictureAt == nil { firstPictureAt = now }
    }

    public mutating func note(transport: VideoTransport) {
        self.transport = transport
        if transport == .control { fellBack = true }
    }

    /// `nil` when no picture ever arrived, which on a relayed session is the signature of a blocked video lane with no fallback in time.
    public var firstPictureMilliseconds: Int? {
        guard let readyAt, let firstPictureAt, firstPictureAt >= readyAt else { return nil }
        return Int(((firstPictureAt - readyAt) * 1000).rounded())
    }
}
