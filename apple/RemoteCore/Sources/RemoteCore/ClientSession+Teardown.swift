import CryptoKit
import Crypto
import Foundation
import Network
import Security
import os

extension ClientSession {
    func controlClosed(_ failure: ClientConnection.Failure) {
        lock.lock()
        let wasFailed = state == .failed
        let deliberate = failure == .cancelled
        lock.unlock()

        if deliberate {
            guard !wasFailed else { return }
            emit(.phase(.disconnected))
            return
        }
        // The Mac's own explanation arrives as an `.error` frame immediately before the
        // close. Reporting the close as well would replace a sentence the user can act on
        // with "connection reset".
        guard !wasFailed else { return }
        fail(failure.errorDescription ?? "The connection ended.", reason: FailureReason(failure), cause: FailureCause(failure))
    }

    func fail(_ failure: Failure) {
        fail(failure.errorDescription ?? "", reason: failure.reason, cause: failure.cause)
    }

    func fail(_ message: String, reason: FailureReason, cause: FailureCause? = nil) {
        lock.lock()
        // The first failure is the one that counts: a connection that fails is reported twice (the transport's close handler and the `catch` in `connect`), and this guard keeps the property and event stream from holding two sentences.
        guard state != .failed else {
            lock.unlock()
            return
        }
        connectGeneration &+= 1
        state = .failed
        _phase = .failed(message)
        _failureReason = reason
        _failureCause = cause
        _failureDiagnosis = diagnosisLocked(reason: reason, detail: self.control?.errorDetail)
        let video = self.video
        let videoConnect = self.videoConnectTask
        let videoReconnect = self.videoReconnectTask
        let control = self.control
        let relayProxy = self.relayProxy
        let datagrams = self.videoDatagrams
        self.video = nil
        self.videoConnectTask = nil
        self.videoReconnectTask = nil
        self.control = nil
        self.relayProxy = nil
        self.videoDatagrams = nil
        self.relaySession = nil
        directPathTask?.cancel()
        directPathTask = nil
        reportedPath = .relay
        pingTask?.cancel()
        pingTask = nil
        let videoWatch = stopVideoWatchLocked()
        lock.unlock()

        previewRequests.failAll(.disconnected)
        videoWatch?.cancel()
        videoConnect?.cancel()
        videoReconnect?.cancel()
        clientSessionLog.error("session failed: \(message, privacy: .public)")
        emit(.phase(.failed(message)))
        // The video socket carries no handshake of its own and is authorized only by this
        // control session, so it dies with it. The datagram lane is the same arrangement one
        // step further out: the relay only forwards it while the session it belongs to lives.
        video?.cancel()
        datagrams?.cancel()
        relayProxy?.cancel()
        control?.cancel()
    }
}

extension ClientSession {
    // MARK: - Teardown

    public func disconnect() {
        lock.lock()
        connectGeneration &+= 1
        let control = self.control
        let video = self.video
        let videoConnect = self.videoConnectTask
        let videoReconnect = self.videoReconnectTask
        let relayProxy = self.relayProxy
        let datagrams = self.videoDatagrams
        self.control = nil
        self.video = nil
        self.videoConnectTask = nil
        self.videoReconnectTask = nil
        self.relayProxy = nil
        self.videoDatagrams = nil
        self.relaySession = nil
        directPathTask?.cancel()
        directPathTask = nil
        reportedPath = .relay
        usesRelayedSingleStream = false
        pingTask?.cancel()
        pingTask = nil
        let videoWatch = stopVideoWatchLocked()
        state = .idle
        _phase = .disconnected
        ephemeral = nil
        nonce = nil
        remoteCommitment = nil
        lock.unlock()

        videoWatch?.cancel()
        videoConnect?.cancel()
        videoReconnect?.cancel()
        coalescer.flush()
        video?.cancel()
        datagrams?.cancel()
        control?.cancel()
        relayProxy?.cancel()
        emit(.phase(.disconnected))
    }
}
