import Foundation

extension TerminalSessionManager {
    /// A file being written, between the request that opened it and the piece that closes it.
    final class PendingWrite: @unchecked Sendable {
        let ownerClientID: String
        let path: String
        /// What the client said it was sending. The last piece is refused unless this many bytes
        /// arrived, so a transfer that stopped early is a failed write rather than a short file.
        let expected: Int
        /// The destination as the filesystem will see it. Resolved once when the transfer opens
        /// rather than at the move, because the scratch file has to be created in the same
        /// directory as the file it becomes: a rename across volumes is a copy, and a copy is not
        /// one step and can be left half done.
        let target: URL
        let staging: URL
        var handle: FileHandle?
        /// How many bytes have been appended. Touched only under the manager's lock.
        var received = 0
        /// When a piece last arrived, on the uptime clock. Touched only under the manager's lock.
        var lastActivity = ProcessInfo.processInfo.systemUptime
        /// The first thing that went wrong writing to disk, if anything did.
        var failure: String?

        init(ownerClientID: String, path: String, expected: Int, target: URL, staging: URL) {
            self.ownerClientID = ownerClientID
            self.path = path
            self.expected = expected
            self.target = target
            self.staging = staging
        }

        /// Pieces already queued behind this call find `failure` set and write nothing, instead of reopening the file.
        func discard() {
            failure = failure ?? "discarded"
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: staging)
        }
    }

    /// One terminal's write to one path.
    struct WriteKey: Hashable {
        let sessionID: UUID
        let path: String
    }
}
