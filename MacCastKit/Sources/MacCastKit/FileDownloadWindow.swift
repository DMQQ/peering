import Foundation
import RemoteCore

/// Which pieces of a download to ask for next. Pure arithmetic, kept apart from the session that sends the requests.
public struct FileDownloadWindow: Equatable, Sendable {
    public private(set) var totalBytes: Int64?
    public private(set) var requestedUpTo: Int64 = 0
    public private(set) var receivedBytes: Int64 = 0
    public private(set) var inFlight = 0

    public init() {}

    /// The first piece, asked for before the size is known.
    public mutating func first() -> Int64 {
        requestedUpTo = Int64(FileDownloadLimits.chunkBytes)
        inFlight = 1
        return 0
    }

    /// Records a piece that arrived, and says what to ask for now: enough to keep the window full, never past the end.
    public mutating func received(count: Int, totalBytes: Int64) -> [Int64] {
        self.totalBytes = totalBytes
        receivedBytes += Int64(count)
        inFlight = max(0, inFlight - 1)
        var offsets: [Int64] = []
        while inFlight < FileDownloadLimits.window, requestedUpTo < totalBytes {
            offsets.append(requestedUpTo)
            requestedUpTo += Int64(FileDownloadLimits.chunkBytes)
            inFlight += 1
        }
        return offsets
    }

    public var isComplete: Bool {
        guard let totalBytes else { return false }
        return receivedBytes >= totalBytes
    }

    /// 0 to 1, or nil until the size is known.
    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }
}
