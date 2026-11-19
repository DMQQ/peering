import CryptoKit
import Crypto
import Foundation
import Network
import Security
import os

extension ClientSession {
    /// Asks the relay where the Mac is, then tries a path straight to it. Silent on every failure by design: a session that cannot reach its peer is on the relay, the ordinary case.
    func beginDirectPath(secret: Data) {
        guard let pair = lock.withLock({ () -> (VideoDatagramSocket, RelaySession)? in
            guard let socket = videoDatagrams, let relay = relaySession else { return nil }
            return (socket, relay)
        }) else { return }
        let (socket, relay) = pair

        let schedule = VideoKeySchedule(secret: secret)
        guard let sealer = try? schedule.sealer(token: relay.videoToken, direction: .clientToHost)
        else {
            clientSessionLog.error("could not build the key for the direct video path, so the session stays on the relay")
            return
        }
        let laneStillExists = lock.withLock { () -> Bool in
            guard videoDatagrams === socket else { return false }
            videoSealer = sealer
            return true
        }
        guard laneStillExists else { return }
        // With streams the control connection stays on the relay's TCP: no ordered stream rides the lane, and what needs the lane's latency travels on streams that do.
        if lock.withLock({ streams == nil }) { attachControlPipe(to: socket) }

        let pingTask = makeLanePingTask(socket)
        let directTask = Task { [weak self] in
            guard let self,
                  self.lock.withLock({ self.videoDatagrams === socket })
            else { return }

            // Fast while there is any prospect, then slow for the rest of the session to recover a path a NAT mapping expiry took away. Each probe is sealed afresh: the counter is the AEAD nonce, so a reused probe would be discarded. Discovery repeats on the same cadence, since "no address yet" is the ordinary first answer.
            let lookup = RelayPeerLookup(url: ProtocolInfo.relaySignallingURL)
            var schedule = DirectPathSchedule()
            var seenRestarts = self.lock.withLock { self.directPathRestarts }
            while !Task.isCancelled {
                if schedule.asksRelayForPeerAddress, !socket.pathIsLive {
                    if let address = try? await lookup.address(videoToken: relay.videoToken) {
                        // Not fatal but said: an unparseable address would go unnoticed all session. ``sendDirect`` does nothing meanwhile rather than sending to the relay.
                        let peer = "\(address.host):\(address.port)"
                        do {
                            try socket.setDirectPeer(host: address.host, port: address.port)
                            self.reportDirectPath(.probing(peer: peer))
                        } catch {
                            self.reportDirectPath(.addressUnusable(peer: peer))
                        }
                    } else {
                        self.reportDirectPath(.noAddress)
                    }
                }

                let probe = self.sealOnVideoLane(kind: .directProbe, payload: Data())
                if !probe.isEmpty {
                    socket.sendDirect(probe) { _ in }
                }
                schedule.probeSent()
                if schedule.verdictIsDue(now: .now) {
                    self.reportDirectPath(self.lock.withLock { self.reportedDirectPath }.verdict())
                }

                // Woken early by a network change, so the new network is knocked on at once and not after the slow interval.
                var waited = Duration.zero
                while waited < schedule.intervalToNextProbe, !Task.isCancelled,
                      self.lock.withLock({ self.directPathRestarts }) == seenRestarts {
                    try? await Task.sleep(for: DirectPathSchedule.fastInterval)
                    waited += DirectPathSchedule.fastInterval
                }
                let restarts = self.lock.withLock { self.directPathRestarts }
                if restarts != seenRestarts {
                    seenRestarts = restarts
                    schedule.restart(now: .now)
                    self.reportDirectPath(.notTried)
                }
            }
            await lookup.close()
        }

        let previous = lock.withLock { () -> (Task<Void, Never>?, Task<Void, Never>?)? in
            guard videoDatagrams === socket else { return nil }
            let previous = (directPathTask, lanePingTask)
            directPathTask = directTask
            lanePingTask = pingTask
            return previous
        }
        guard let previous else {
            directTask.cancel()
            pingTask.cancel()
            return
        }
        previous.0?.cancel()
        previous.1?.cancel()
    }

    /// The phone's network changed: the path that was proven belongs to the old one. The picture goes by the relay until a probe proves a path on the new network, the relay is told the new address, and the knocking starts over at its fast pace.
    public func restartDirectPath() {
        let (socket, hasMover) = lock.withLock { () -> (VideoDatagramSocket?, Bool) in
            directPathRestarts += 1
            return (videoDatagrams, quicDirectPath != nil)
        }
        socket?.pathChanged()
        // A QUIC session with a mover handles the change itself; one that began on the LAN has none yet and is carried onto the relay.
        if !hasMover, lock.withLock({ state == .ready }) { carryOverToRelay() }
    }

    /// Measures the lane the picture is on, once a second. The control lane's figure is the relay's even when the picture is direct. Seals through ``sealOnVideoLane(kind:payload:)``: a second sealer would repeat nonces.
    func makeLanePingTask(_ socket: VideoDatagramSocket) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                guard !Task.isCancelled, let self else { return }
                let ping = self.lock.withLock {
                    self.pathPingLedger.record(now: DispatchTime.now().uptimeNanoseconds)
                }
                let payload = (try? MessageCodec.encode(PingPayload(sequence: ping.sequence))) ?? Data()
                let sealed = self.sealOnVideoLane(kind: .ping, payload: payload)
                if !sealed.isEmpty { socket.send(sealed) { _ in } }
            }
        }
    }

    /// Seals one message onto the datagram lane through the single sealer: a second one would reuse AEAD nonces.
    func sealOnVideoLane(kind: MessageKind, payload: Data) -> [Data] {
        lock.withLock {
            guard var sealer = videoSealer else { return [] }
            defer { videoSealer = sealer }
            return sealer.seal(kind: kind, payload: payload)
        }
    }

    func notePathLatency(_ frame: Frame, from source: VideoDatagramSocket.Source) {
        let now = DispatchTime.now()
        let reported = lock.withLock { () -> Double? in
            let sequence = (try? MessageCodec.decode(PingPayload.self, from: frame.payload))?.sequence
            guard let ping = pathPingLedger.answered(sequence: sequence) else { return nil }
            pathLatency.add(
                Double(now.uptimeNanoseconds - ping.sentAtNanoseconds) / 1_000_000,
                at: Self.monotonicNow()
            )
            return pathLatency.reported
        }
        guard let reported else { return }
        emit(.pathLatency(milliseconds: reported, fromPeer: source != .relay))
    }

    /// One datagram from the relay, opened and fed into the path a whole frame takes. Reports a change of path once, not per datagram; the note goes with the change to direct only, since falling back is the ordinary case.
    func noteDatagramPath(_ source: VideoDatagramSocket.Source) {
        var path: DatagramPath = .relay
        if case .peer(let host, let port) = source {
            path = .direct
            lock.withLock { lastPeerDatagramAt = Self.monotonicNow() }
            // The address the Mac is answering from: a NAT that moved mid-session is the ordinary case, and this end finds out.
            reportDirectPath(.open(peer: "\(host):\(port)"))
        }
        let changed = lock.withLock { () -> Bool in
            guard reportedPath != path else { return false }
            reportedPath = path
            return true
        }
        guard changed else { return }
        emit(.path(path))
        if path == .direct {
            emit(.note("The picture is coming straight from the Mac."))
        }
    }

    /// Says what the direct-path attempt has come to, once per change.
    func reportDirectPath(_ outcome: DirectPath) {
        let changed = lock.withLock { () -> Bool in
            guard let next = reportedDirectPath.updated(with: outcome) else { return false }
            reportedDirectPath = next
            return true
        }
        guard changed else { return }
        emit(.directPath(outcome))
    }

    /// An authenticated datagram arrived from this address, so it is where the Mac is, whichever of the announced addresses it was.
    private func adopt(host: String, port: UInt16) {
        guard let socket = lock.withLock({ videoDatagrams }) else { return }
        do {
            try socket.adoptPeer(host: host, port: port)
        } catch {
            clientSessionLog.error("the address the Mac answered from could not be used: \(String(describing: error), privacy: .public)")
        }
    }

    /// The Mac announced addresses it can be reached at (a port its router opened for it): each is probed alongside the one the relay named.
    private func addProbeTargets(from frame: Frame) {
        guard let socket = lock.withLock({ videoDatagrams }) else { return }
        for target in DirectCandidates.targets(in: frame.payload) {
            do {
                try socket.addProbeTarget(host: target.host, port: target.port)
            } catch {
                clientSessionLog.error("an address the Mac announced could not be used: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func handleDatagram(_ datagram: Data, from source: VideoDatagramSocket.Source) {
        let outcome = lock.withLock { () -> Result<Frame?, any Error> in
            guard let current = videoOpener else { return .success(nil) }
            // Mutated in place rather than copied: the replay window and the partial picture
            // being assembled *are* the state, and opening through a copy would forget both.
            var opener = current
            defer { videoOpener = opener }
            do { return .success(try opener.open(datagram)) } catch { return .failure(error) }
        }

        switch outcome {
        case .success(let frame):
            guard let frame else { return }
            noteDatagramPath(source)
            if case .peer(let host, let port) = source { adopt(host: host, port: port) }
            if frame.kind == .directCandidates {
                addProbeTargets(from: frame)
                return
            }
            if frame.kind == .stream {
                lock.withLock { streams }?.receive(frame.payload)
                return
            }
            if frame.kind == .controlPipe {
                lock.withLock { relayProxy }?.receiveDirect(frame.payload)
                return
            }
            // A probe has done its job by opening: it proved the datagram came from the peer, and its source address is now where the Mac sends. Nothing to render.
            guard frame.kind != .directProbe else { return }
            // A lane ping's reply, timed here rather than passed on: everything else the opener
            // produces is a piece of the picture, and the renderer would try to read this as one.
            guard frame.kind != .pong else {
                notePathLatency(frame, from: source)
                return
            }
            lock.withLock { picturesFromPeer += 1 }
            handleVideoFrame(frame, from: .primary)

        case .failure(let error):
            // Counted, logged, and never dropped in silence: a datagram that does not authenticate
            // is the only thing that tells "this network is losing video" apart from "these two
            // ends are not speaking the same key", and the second has no other symptom at all.
            let (total, firstTime) = lock.withLock { () -> (Int, Bool) in
                datagramFailures += 1
                let first = !reportedDatagramFailure
                reportedDatagramFailure = true
                return (datagramFailures, first)
            }
            if total == 1 || total % 512 == 0 {
                clientSessionLog.error("""
                    a video datagram did not authenticate \
                    (\(String(describing: error), privacy: .public)) · \
                    \(total, privacy: .public) so far
                    """
                )
            }
            if firstTime {
                emit(.note("Some of the Mac's video datagrams could not be read; the picture may fall back to the control channel."))
            }
        }
    }
}
