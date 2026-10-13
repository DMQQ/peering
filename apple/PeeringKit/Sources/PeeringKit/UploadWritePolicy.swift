import Foundation

/// The host's rules for files a phone sends to it: how much may wait for the disk, when a silent transfer is given up, and which leftovers are ours to delete.
public enum UploadWritePolicy {
    /// Bytes accepted from the network and not yet on disk, across all transfers. Past this the disk is not keeping up and the transfer is refused, since the alternative is memory that grows until the process is killed.
    public static let maximumQueuedBytes = 16 * 1024 * 1024
    /// A transfer that sends nothing for this long is dropped and its scratch file deleted.
    public static let idleSeconds: TimeInterval = 90
    public static let maximumConcurrentTransfers = 8

    /// The keys whose last piece (or opening) is older than the limit.
    public static func idle<Key: Hashable>(
        _ lastActivity: [Key: TimeInterval], now: TimeInterval, limit: TimeInterval = idleSeconds
    ) -> [Key] {
        lastActivity.filter { now - $0.value >= limit }.map(\.key)
    }

    /// Whether a file name is a scratch file made by a transfer here: `.name.peering-<UUID>.part`.
    public static func isStagingFile(named name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".part"),
              let marker = name.range(of: ".peering-", options: .backwards)
        else { return false }
        let identifier = name[marker.upperBound..<name.index(name.endIndex, offsetBy: -".part".count)]
        return UUID(uuidString: String(identifier)) != nil
    }
}

/// Counts bytes that have been accepted and not yet written.
public struct QueuedByteBudget: Sendable, Equatable {
    public let limit: Int
    public private(set) var queued = 0

    public init(limit: Int = UploadWritePolicy.maximumQueuedBytes) {
        self.limit = limit
    }

    public mutating func reserve(_ bytes: Int) -> Bool {
        guard queued + bytes <= limit else { return false }
        queued += bytes
        return true
    }

    public mutating func release(_ bytes: Int) {
        queued = max(0, queued - bytes)
    }
}
