import CryptoKit
import Crypto
import Foundation
import Network
import Security

extension VideoDatagramSocket {
    enum Destination: Equatable {
        case relay
        case peer
    }

    /// One held group, remembering the destination chosen for it. Remembered rather than recomputed
    /// at the flush: a group held before the bind was chosen for the path as it stood then, and
    /// re-deciding later would move a session's first frames onto a path not yet proved.
    struct Held {
        let datagrams: [Data]
        let destination: Destination
        let completion: (@Sendable (Error?) -> Void)?
    }

    /// Belief, not proof, and the whole of the switching rule: live while the peer has been heard
    /// from recently, dead the moment it has not, with nothing negotiated or signalled, so the
    /// fallback to the relay is automatic rather than a recovery path somebody has to trigger.
    var directPathIsLive: Bool {
        guard peerAddress != nil, let last = lastPeerAt else { return false }
        return Date().timeIntervalSince(last) < Self.directPathIdleTimeout
    }

    /// The loop is what makes one read source serve a burst: a dispatch source fires once when the
    /// socket becomes readable, and a picture arriving as forty datagrams is one event and forty
    /// reads. It stops on `EAGAIN`, which is the buffer being empty rather than a failure.
    func drain() {
        guard !stopped else { return }
        var buffer = [UInt8](repeating: 0, count: VideoDatagram.maxDatagramSize)

        // Checked per datagram: a callback below may cancel the socket mid-burst.
        while !stopped {
            var from = sockaddr_storage()
            var fromLength = socklen_t(MemoryLayout<sockaddr_storage>.size)

            let read: Int = withUnsafeMutablePointer(to: &from) { storage in
                storage.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                    buffer.withUnsafeMutableBytes { bytes -> Int in
                        guard let base = bytes.baseAddress else { return -1 }
                        return recvfrom(fd, base, bytes.count, 0, pointer, &fromLength)
                    }
                }
            }

            if read < 0 {
                if errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                    onFailure?(VideoDatagramError.socketReadFailed(errno))
                }
                return
            }
            guard read > 0 else { return }

            let source: Source
            if Self.sameAddress(from, relayAddress) {
                source = .relay
            } else if let origin = Self.describe(from, length: fromLength) {
                source = .peer(host: origin.host, port: origin.port)
            } else {
                // An address that cannot be named is one this end could not send back to, so it is
                // not a path however it arrived, and it counts with the relay's traffic.
                source = .relay
            }

            let fromPeer = source != .relay
            counterLock.withLock {
                _received += 1
                if fromPeer { _receivedFromPeer += 1 }
            }
            if fromPeer { lastPeerAt = Date() }
            onDatagram?(Data(buffer[0..<read]), source)
        }
    }

    func enqueue(
        _ datagrams: [Data],
        direct: Bool,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        guard !datagrams.isEmpty else {
            completion(nil)
            return
        }
        queue.async { [weak self] in
            guard let self, !self.stopped else {
                completion(nil)
                return
            }
            let destination: Destination = direct || self.directPathIsLive ? .peer : .relay

            // The token comes off exactly when the datagram is not going to the relay, and here
            // rather than in the caller, because this is the only place that knows where it is
            // going: the relay needs the token, and a peer reading it as a counter refuses every
            // datagram, which looks exactly like a lossy path.
            let payloads = destination == .peer
                ? datagrams.map { $0.dropFirst(VideoDatagram.tokenSize) }
                : datagrams

            guard self.bound else {
                // Waiting for the bind. The oldest goes when the queue is full: a stale picture is
                // worth less than the one that just arrived.
                self.held.append(Held(
                    datagrams: payloads,
                    destination: destination,
                    completion: completion
                ))
                self.heldCount += payloads.count
                // The newest is always kept, even alone larger than the cap: it is the picture the
                // client has not seen, and the ones being dropped are not.
                while self.heldCount > Self.maxHeldDatagrams, self.held.count > 1 {
                    self.heldCount -= self.held.removeFirst().datagrams.count
                }
                return
            }
            self.write(payloads, to: destination, completion: completion)
        }
    }

    /// Always to the relay, even once a direct path is carrying the picture: a direct path is built
    /// on that address rather than instead of it, so a punch that later stopped working still has
    /// somewhere to fall back to.
    func sendBind() {
        write([token], to: .relay) { [weak self] error in
            guard let self else { return }
            if let error {
                // The bind is the one send that has to work: without it the relay has nowhere to
                // forward from, and every send after it would be held waiting for a bind that is
                // not coming, which is a pump that never runs again rather than a dropped picture.
                // So the socket is closed instead.
                self.onFailure?(error)
                self.stopOnQueue()
                return
            }
            self.bound = true
            self.flushHeld()
        }
    }

    func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        bindTimer?.cancel()
        bindTimer = nil
        let waiting = held
        held.removeAll()
        heldCount = 0
        if let source = readSource {
            // libdispatch aborts on a descriptor closed under a live source (EV_VANISHED), and the number is reused by the next socket while the source still holds it. The handler captures the number, not self: deinit reaches here.
            let descriptor = fd
            source.setCancelHandler { close(descriptor) }
            source.cancel()
            readSource = nil
        } else {
            close(fd)
        }
        for entry in waiting { entry.completion?(nil) }
    }

    func flushHeld() {
        guard !held.isEmpty else { return }
        let waiting = held
        held.removeAll(keepingCapacity: true)
        heldCount = 0

        // Grouped by destination, because one flush can straddle both: the frames held before a bind
        // went to the relay, and the path may have been proved by the time the bind lands. Each
        // group is a single write, so every caller in it is told the same moment.
        for destination in [Destination.relay, .peer] {
            let group = waiting.filter { $0.destination == destination }
            guard !group.isEmpty else { continue }
            write(group.flatMap(\.datagrams), to: destination) { error in
                for entry in group { entry.completion?(error) }
            }
        }
    }

    /// A full send buffer is not reported as a failure: datagrams are already allowed to be lost,
    /// and calling "would block" an error would tear down a session over a busy link.
    func write(
        _ datagrams: [Data],
        to destination: Destination,
        completion: (@Sendable (Error?) -> Void)?
    ) {
        // The descriptor outlives `stopped` until the cancel handler runs, but nothing should be sent on it.
        guard !stopped else {
            completion?(nil)
            return
        }
        var address = destination == .peer ? (peerAddress ?? relayAddress) : relayAddress
        let peerIsSet = peerAddress != nil
        let length = destination == .peer && peerIsSet ? peerLength : relayLength

        var failure: Error?
        for datagram in datagrams {
            let result: Int = datagram.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return withUnsafePointer(to: &address) { storage in
                    storage.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                        sendto(fd, base, bytes.count, 0, pointer, length)
                    }
                }
            }
            if result < 0, errno != EAGAIN, errno != EWOULDBLOCK, failure == nil {
                failure = VideoDatagramError.sendFailed(errno)
            }
        }

        counterLock.withLock { _sent += datagrams.count }
        if let failure { onFailure?(failure) }
        completion?(failure)
    }

    func startBindTimer() {
        guard bindTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.keepaliveInterval,
            repeating: Self.keepaliveInterval,
            leeway: .seconds(1)
        )
        // The bind, not a sealed datagram: it is the address the relay remembers, and the video
        // itself keeps the other direction's mapping warm simply by existing.
        timer.setEventHandler { [weak self] in self?.sendBind() }
        timer.resume()
        bindTimer = timer
    }
}
