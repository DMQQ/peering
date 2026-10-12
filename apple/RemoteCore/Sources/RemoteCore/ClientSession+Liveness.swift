import CryptoKit
import Crypto
import Foundation
import Network
import Security
import os

extension ClientSession {
    static let pingInterval: Duration = .seconds(1)

    /// How long a round trip stays in the reported figure: a duration, not a count, so one bad round trip does not own it.
    static let latencyWindow: TimeInterval = 10

    /// Probe attempts between two asks at the relay for the peer's address: twelve, one re-ask per three seconds when fast and one per minute once slowed.
    static let rediscoverEvery = 12

    func startPinging() {
        lock.lock()
        guard pingTask == nil else { lock.unlock(); return }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                guard !Task.isCancelled, let self else { return }
                self.sendPing()
            }
        }
        pingTask = task
        lock.unlock()
    }

    func sendPing() {
        let ping = lock.withLock {
            pingLedger.record(now: DispatchTime.now().uptimeNanoseconds)
        }
        // The payload is what makes the reply measurable. A Mac that does not echo it
        // answers empty, which the ledger reads as the oldest question still open.
        let payload = (try? MessageCodec.encode(PingPayload(sequence: ping.sequence))) ?? Data()
        connection()?.send(Frame(kind: .ping, payload: payload))
    }

    static func answerGrace(roundTripMilliseconds: Double?) -> TimeInterval {
        guard let roundTripMilliseconds else { return 1.0 }
        return min(1.5, max(0.4, roundTripMilliseconds * 4 / 1000 + 0.2))
    }

    /// The median of the last few round trips: a single ping flickers, and a mean would let one stalled ping drag the figure up.
    func reportLatency(for frame: Frame) {
        let now = DispatchTime.now()
        let monotonic = Self.monotonicNow()

        let reported = lock.withLock { () -> Double? in
            // A pong is the only proof the control channel works; the fallback asks before moving the picture onto it.
            lastControlReplyAt = monotonic

            let sequence = (try? MessageCodec.decode(PingPayload.self, from: frame.payload))?.sequence
            guard let ping = pingLedger.answered(sequence: sequence) else { return nil }

            latency.add(
                Double(now.uptimeNanoseconds - ping.sentAtNanoseconds) / 1_000_000,
                at: monotonic
            )
            return latency.reported
        }

        guard let reported else { return }
        emit(.latency(milliseconds: reported))
    }
}

extension ClientSession {
    // MARK: - Liveness

    /// Fails the session unless the Mac answers within a few round trips, for when a session may look healthy with nothing under it (network just changed, app just resumed). The wait scales with the measured round trip so a same-Wi-Fi Mac is not made to wait out a relay-sized figure.
    public func verifyStillAnswering() {
        let askedAt = Self.monotonicNow()
        let (isReady, roundTrip) = lock.withLock { (state == .ready, latency.reported) }
        guard isReady else { return }
        let grace = Self.answerGrace(roundTripMilliseconds: roundTrip)
        sendPing()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard let self else { return }
            let silent = self.lock.withLock {
                self.state == .ready && (self.lastControlReplyAt ?? 0) < askedAt
            }
            guard silent else { return }
            clientSessionLog.error("no answer within \(grace, privacy: .public)s of being asked; failing the session")
            self.fail("The Mac stopped answering. It may have moved networks, or the connection was interrupted.", reason: .unresponsiveAfterCheck, cause: .hostUnresponsive)
        }
    }
}
