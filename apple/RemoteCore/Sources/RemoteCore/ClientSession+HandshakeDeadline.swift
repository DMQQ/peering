import Foundation

extension ClientSession {
    /// The states in which only the Mac can move things on. Waiting for the person to compare codes is not one of them.
    static func isStalled(_ state: HandshakeState) -> Bool {
        switch state {
        case .awaitingServerHello, .awaitingServerCommit, .awaitingServerReveal: return true
        case .idle, .awaitingUserConfirmation, .awaitingPairResult, .ready, .failed: return false
        }
    }

    func armHandshakeDeadline(generation: UInt64, seconds: TimeInterval = ConnectDeadlines.handshake) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.handshakeDeadlineReached(generation: generation)
        }
    }

    private func handshakeDeadlineReached(generation: UInt64) {
        let stalled = lock.withLock { connectGeneration == generation && Self.isStalled(state) }
        if stalled { fail(Failure.handshakeTimedOut) }
    }
}
