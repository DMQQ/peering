import Foundation

/// The bytes a sender may have handed to the network without the network having taken them.
/// Pure so the rule can be tested without a connection.
struct SendWindowState: Equatable {
    enum Admission: Equatable {
        case admitted
        case wait
        case refused(SendWindowFailure)
    }

    let limit: Int
    private(set) var inFlight = 0
    private(set) var failure: SendWindowFailure?

    init(limit: Int) { self.limit = limit }

    /// A piece larger than the whole window is still admitted when nothing else is in flight, so an oversized piece cannot wait forever.
    mutating func reserve(_ bytes: Int) -> Admission {
        if let failure { return .refused(failure) }
        guard inFlight == 0 || inFlight + bytes <= limit else { return .wait }
        inFlight += bytes
        return .admitted
    }

    mutating func complete(_ bytes: Int, errorText: String?) {
        inFlight = max(0, inFlight - bytes)
        if failure == nil, let errorText { failure = .failed(errorText) }
    }

    mutating func cancel() {
        if failure == nil { failure = .cancelled }
    }
}

/// Why a windowed send stopped: the sender cancelled, or the network reported an error.
public enum SendWindowFailure: Error, Equatable, Sendable, LocalizedError {
    case cancelled
    case failed(String)

    public var isCancelled: Bool { self == .cancelled }

    public var errorDescription: String? {
        switch self {
        case .cancelled: return nil
        case .failed(let message): return message
        }
    }
}

/// Back pressure for a long transfer: `reserve` suspends while too many bytes are still waiting on the network, so memory stays at about the limit however fast the source is.
/// A send error is remembered and fails every later `reserve`.
public final class SendWindow: @unchecked Sendable {
    public static let defaultLimit = 1024 * 1024

    // `state` and `waiters` are guarded by `lock`; continuations are resumed after it is released.
    private let lock = NSLock()
    private var state: SendWindowState
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Error>)] = []

    public init(limit: Int = SendWindow.defaultLimit) {
        state = SendWindowState(limit: limit)
    }

    public func reserve(_ bytes: Int) async throws {
        while !(try await attempt(bytes)) {}
    }

    public func complete(_ bytes: Int, error: Error?) {
        let text = error.map { NetworkFailureText.describe($0) }
        release { $0.complete(bytes, errorText: text) }
    }

    public func cancel() {
        release { $0.cancel() }
    }

    private func release(_ change: (inout SendWindowState) -> Void) {
        let released = lock.withLock { () -> [CheckedContinuation<Bool, Error>] in
            change(&state)
            defer { waiters = [] }
            return waiters.map(\.continuation)
        }
        for waiter in released { waiter.resume(returning: false) }
    }

    /// `true` once admitted, `false` after a wait that ended and needs asking again. A cancelled task stops waiting at once.
    private func attempt(_ bytes: Int) async throws -> Bool {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                let resume: () -> Void = lock.withLock {
                    if Task.isCancelled { return { continuation.resume(throwing: CancellationError()) } }
                    switch state.reserve(bytes) {
                    case .admitted: return { continuation.resume(returning: true) }
                    case .refused(let failure): return { continuation.resume(throwing: failure) }
                    case .wait:
                        waiters.append((id, continuation))
                        return {}
                    }
                }
                resume()
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<Bool, Error>? in
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index).continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
}
