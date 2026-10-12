import Foundation
import RemoteCore

/// Which pieces of a download to ask for next. Pure arithmetic, kept apart from the session that sends the requests.
public struct FileDownloadWindow: Equatable, Sendable {
    public private(set) var totalBytes: Int64?
    public private(set) var requestedUpTo: Int64 = 0
    public private(set) var receivedBytes: Int64 = 0
    public private(set) var inFlight = 0
    /// Offsets asked for and not yet answered: an answer is accepted once, and only for one of these.
    public private(set) var outstanding: Set<Int64> = []

    public init() {}

    public enum Rejection: Error, Equatable, Sendable {
        case tooLarge
        case noRoomOnDisk
        /// An offset nobody asked for, asked for twice, negative or past the end; a size that changed; a piece longer than asked.
        case unexpectedData
    }

    /// The first piece, asked for before the size is known.
    public mutating func first() -> Int64 {
        requestedUpTo = Int64(FileDownloadLimits.chunkBytes)
        inFlight = 1
        outstanding = [0]
        return 0
    }

    /// Checks an answer against what was asked before it is written anywhere, then counts it as ``received(count:totalBytes:)`` does.
    /// - Parameter freeDiskBytes: `nil` when it cannot be read, which skips only that check.
    public mutating func accept(
        offset: Int64, count: Int, totalBytes: Int64, freeDiskBytes: Int64?
    ) -> Result<[Int64], Rejection> {
        guard totalBytes >= 0, totalBytes <= FileDownloadLimits.maximumBytes else { return .failure(.tooLarge) }
        if let freeDiskBytes, totalBytes > freeDiskBytes { return .failure(.noRoomOnDisk) }
        if let known = self.totalBytes, known != totalBytes { return .failure(.unexpectedData) }
        guard outstanding.contains(offset),
              count >= 0, count <= FileDownloadLimits.chunkBytes,
              offset + Int64(count) <= totalBytes
        else { return .failure(.unexpectedData) }
        outstanding.remove(offset)
        return .success(received(count: count, totalBytes: totalBytes))
    }

    /// Records a piece that arrived, and says what to ask for now: enough to keep the window full, never past the end.
    public mutating func received(count: Int, totalBytes: Int64) -> [Int64] {
        self.totalBytes = totalBytes
        receivedBytes += Int64(count)
        inFlight = max(0, inFlight - 1)
        var offsets: [Int64] = []
        while inFlight < FileDownloadLimits.window, requestedUpTo < totalBytes {
            offsets.append(requestedUpTo)
            outstanding.insert(requestedUpTo)
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
