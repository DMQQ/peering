import Foundation
import Network
import os

private let pipeLog = Logger(subsystem: "pl.dmq.peering", category: "control-pipe")

/// Joins a local TCP endpoint (where TLS runs) to the far end through the control pipe, over the relay's TCP connection and, while a direct path is live, over the datagram lane instead. The relay stays connected the whole time and is what the stream falls back to; neither carrier can read the bytes, which are TLS.
final class ControlPipeSplice: @unchecked Sendable {
    private enum Carrier { case relay, direct }

    private struct DirectLane {
        let send: @Sendable (Data) -> Void
        let isLive: @Sendable () -> Bool
    }

    private let local: NWConnection
    private let relay: NWConnection
    private let token: Data
    private let queue: DispatchQueue
    private let onStop: (@Sendable () -> Void)?

    // Everything below is touched only on `queue`.
    private var localReady = false
    private var relayReady = false
    private var tokenSent = false
    private var pumping = false
    private var stopped = false
    private var localReadPaused = false
    private var sender = ControlPipeSender()
    private var receiver = ControlPipeReceiver()
    private var decoder = ControlPipeLengthDecoder()
    private var lane: DirectLane?
    private var active = Carrier.relay
    private var directBannedUntil: ContinuousClock.Instant?
    private var timer: DispatchSourceTimer?

    private let portLock = NSLock()
    private var _localSourcePort: UInt16?
    var localSourcePort: UInt16? { portLock.withLock { _localSourcePort } }

    /// More than this unacknowledged and the local end is not read until the far end catches up.
    private static let maxBufferedBytes = 512 * 1024
    private static let readSize = 64 * 1024
    private static let tick: DispatchTimeInterval = .milliseconds(100)
    private static let timeoutsBeforeLeavingDirect = 3
    private static let directPenalty: Duration = .seconds(10)

    init(
        local: NWConnection,
        relayHost: String,
        relayPort: UInt16,
        token: Data,
        queue: DispatchQueue,
        onStop: (@Sendable () -> Void)? = nil
    ) throws {
        guard let port = NWEndpoint.Port(rawValue: relayPort) else {
            throw RelayTunnelError.invalidPort(relayPort)
        }
        self.local = local
        relay = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(relayHost), port: port),
            using: relayTCPParameters()
        )
        self.token = token
        self.queue = queue
        self.onStop = onStop
    }

    func start() {
        local.stateUpdateHandler = { [weak self] state in self?.state(state, isLocal: true) }
        relay.stateUpdateHandler = { [weak self] state in self?.state(state, isLocal: false) }
        local.start(queue: queue)
        relay.start(queue: queue)
    }

    func cancel() {
        queue.async { [self] in stop() }
    }

    /// Lets the stream use the datagram lane while `isLive` says it works. `send` carries one sealed frame to the far end.
    func attachDirect(send: @escaping @Sendable (Data) -> Void, isLive: @escaping @Sendable () -> Bool) {
        queue.async { [self] in lane = DirectLane(send: send, isLive: isLive) }
    }

    /// A frame that arrived on the datagram lane, already authenticated.
    func receiveDirect(_ bytes: Data) {
        queue.async { [self] in
            guard !stopped, let frame = ControlPipeFrame.decode(bytes) else { return }
            handle(frame, from: .direct)
        }
    }

    private func state(_ state: NWConnection.State, isLocal: Bool) {
        switch state {
        case .ready:
            if isLocal {
                localReady = true
                if case .hostPort(_, let port)? = local.currentPath?.localEndpoint {
                    portLock.withLock { _localSourcePort = port.rawValue }
                }
            } else {
                relayReady = true
            }
            advance()
        case .failed, .cancelled:
            stop()
        case .waiting(let error):
            // Not a failure: a relay leg with nowhere to go is a phone mid-handover, and the session's silence watchdog ends one that does not recover. Logged because waiting and fine look identical above this layer.
            pipeLog.notice("the relay leg is waiting: \(String(describing: error), privacy: .public)")
        default:
            break
        }
    }

    private func advance() {
        guard !stopped, localReady, relayReady else { return }
        guard tokenSent else {
            tokenSent = true
            relay.send(content: token, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error == nil { self.advance() } else { self.stop() }
            })
            return
        }
        guard !pumping else { return }
        pumping = true
        readLocal()
        readRelay()
        startTimer()
    }

    // MARK: - Local TLS side

    private func readLocal() {
        guard !stopped else { return }
        local.receive(minimumIncompleteLength: 1, maximumLength: Self.readSize) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.sender.enqueue(data)
                self.pump()
            }
            if isComplete || error != nil { self.stop(); return }
            if self.sender.bufferedBytes < Self.maxBufferedBytes {
                self.readLocal()
            } else {
                self.localReadPaused = true
            }
        }
    }

    private func resumeLocalReadIfRoom() {
        guard localReadPaused, sender.bufferedBytes < Self.maxBufferedBytes / 2 else { return }
        localReadPaused = false
        readLocal()
    }

    private func deliverToLocal(_ bytes: Data) {
        local.send(content: bytes, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.stop() }
        })
    }

    // MARK: - Relay side

    private func readRelay() {
        guard !stopped else { return }
        relay.receive(minimumIncompleteLength: 1, maximumLength: Self.readSize) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try self.decoder.feed(data) { self.handle(frame, from: .relay) }
                } catch {
                    pipeLog.error("the relay sent a control frame this end cannot read, so the session is ending: \(String(describing: error), privacy: .public)")
                    self.stop()
                    return
                }
            }
            if isComplete || error != nil { self.stop(); return }
            self.readRelay()
        }
    }

    // MARK: - The pipe

    private func handle(_ frame: ControlPipeFrame, from carrier: Carrier) {
        switch frame {
        case .data(let offset, let payload):
            let ready = receiver.receive(offset: offset, payload: payload)
            if !ready.isEmpty { deliverToLocal(ready) }
            send(.ack(upTo: receiver.ackPoint), on: carrier)
        case .ack(let upTo):
            sender.acknowledge(upTo: upTo, now: .now)
            resumeLocalReadIfRoom()
            pump()
        }
    }

    private func send(_ frame: ControlPipeFrame, on carrier: Carrier) {
        switch carrier {
        case .relay:
            relay.send(content: ControlPipeLengthDecoder.wrap(frame), completion: .contentProcessed { [weak self] error in
                if error != nil { self?.stop() }
            })
        case .direct:
            lane?.send(frame.encoded())
        }
    }

    /// Picks the carrier, and moves what is unacknowledged onto it when that changed. The direct lane is left, for a while, when it stops acknowledging.
    private func chooseCarrier(now: ContinuousClock.Instant) {
        if active == .direct, sender.consecutiveTimeouts >= Self.timeoutsBeforeLeavingDirect {
            directBannedUntil = now + Self.directPenalty
        }
        let banned = directBannedUntil.map { now < $0 } ?? false
        let wanted: Carrier = (lane?.isLive() == true && !banned) ? .direct : .relay
        guard wanted != active else { return }
        active = wanted
        sender.carrierChanged()
        pipeLog.notice("the control stream moved to \(wanted == .direct ? "the direct path" : "the relay", privacy: .public)")
    }

    private func pump() {
        guard !stopped else { return }
        let now = ContinuousClock.now
        chooseCarrier(now: now)
        for frame in sender.frames(now: now, carrier: active == .direct ? .lossy : .reliable) {
            send(frame, on: active)
        }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.tick, repeating: Self.tick)
        timer.setEventHandler { [weak self] in self?.pump() }
        timer.resume()
        self.timer = timer
    }

    private func stop() {
        guard !stopped else { return }
        stopped = true
        timer?.cancel()
        timer = nil
        local.cancel()
        relay.cancel()
        onStop?()
    }
}
