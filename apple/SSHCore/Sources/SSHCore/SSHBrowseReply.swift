import Foundation

/// The one way to answer a browse request: the caller's continuation is resumed at most once, by whichever of the answer and the deadline comes first.
final class SSHBrowseReply: @unchecked Sendable {
    private let continuation: CheckedContinuation<SSHBrowseResult, any Error>
    // `isResolved` is guarded by `lock`.
    private let lock = NSLock()
    private var isResolved = false

    init(_ continuation: CheckedContinuation<SSHBrowseResult, any Error>) {
        self.continuation = continuation
    }

    var isAnswered: Bool { lock.withLock { isResolved } }

    func resume(returning result: SSHBrowseResult) {
        if claim() { continuation.resume(returning: result) }
    }

    func resume(throwing error: any Error) {
        if claim() { continuation.resume(throwing: error) }
    }

    /// Answers with a failure once `delay` passes, unless the real answer got there first.
    func expire(after delay: Duration) {
        Task {
            try? await Task.sleep(for: delay)
            resume(throwing: SSHSessionError.browse("The server did not answer in time."))
        }
    }

    private func claim() -> Bool {
        lock.withLock {
            defer { isResolved = true }
            return !isResolved
        }
    }
}
