import Foundation
import PeeringKit
import RemoteCore

/// A wire in a race is held back until it wins, so a loser's failure never reads as the Mac dropping. Frames and configs are kept, not dropped: a lost config leaves the decoder unable to read until the next one.
nonisolated final class WireGate: @unchecked Sendable {
    private let lock = NSLock()
    private var admitted: Bool
    private var heldVideo: [ClientSession.VideoEvent] = []

    init(admitted: Bool) {
        self.admitted = admitted
    }

    func pass(video event: ClientSession.VideoEvent) -> Bool {
        lock.withLock {
            if admitted { return true }
            heldVideo.append(event)
            return false
        }
    }

    var isAdmitted: Bool { lock.withLock { admitted } }

    /// Under the lock, so a frame arriving meanwhile cannot overtake the held ones.
    func admit(into renderer: VideoRenderer) {
        lock.withLock {
            for event in heldVideo {
                switch event {
                case .frame(let frame): renderer.enqueue(frame)
                case .config(let config): renderer.configure(config)
                default: break
                }
            }
            heldVideo = []
            admitted = true
        }
    }
}

/// LAN is tried first (free and faster); the relay starts after a short head start, sooner if the LAN fails. A relay winner moves onto the LAN later via the usual Bonjour switch.
@MainActor
final class DialRace {
    struct Entry {
        let wire: ClientSession
        let gate: WireGate
        let path: ConnectionPath
        var buffer: [ClientSession.Event] = []
        var failed = false
    }

    private weak var session: MacSession?
    private var entries: [Entry] = []
    private var startLater: Task<Void, Never>?
    private var queued: (() -> Void)?
    private(set) var isDecided = false
    private weak var winner: ClientSession?

    init(session: MacSession) {
        self.session = session
    }

    func add(_ wire: ClientSession, gate: WireGate, path: ConnectionPath) {
        entries.append(Entry(wire: wire, gate: gate, path: path))
    }

    func startLater(after delay: Duration, _ dial: @escaping () -> Void) {
        queued = dial
        startLater = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.startQueued()
        }
    }

    private func startQueued() {
        guard !isDecided, let dial = queued else { return }
        queued = nil
        startLater?.cancel()
        dial()
    }

    func receive(_ event: ClientSession.Event, from wire: ClientSession) {
        guard let index = entries.firstIndex(where: { $0.wire === wire }) else { return }
        // Sent before the winner was admitted and delivered after: still the session's.
        guard !isDecided else {
            if wire === winner { session?.apply(event) }
            return
        }
        guard let session, isStillWanted(by: session) else {
            cancel()
            return
        }
        entries[index].buffer.append(event)
        switch event {
        case .phase(.ready):
            win(index, in: session)
        case .phase(.failed), .phase(.disconnected):
            entries[index].failed = true
            session.noteRouteFailed(entries[index].path, reason: wire.failureReason)
            if queued != nil {
                startQueued()
            } else if entries.allSatisfy(\.failed) {
                // A relay that refused on quota says why; the LAN's timeout, which often comes last, only says the Mac is not on this network.
                let refused = entries.firstIndex { entry in
                    entry.buffer.contains { if case .relayQuotaExceeded = $0 { true } else { false } }
                }
                win(refused ?? index, in: session)
            }
        default:
            break
        }
    }

    private func isStillWanted(by session: MacSession) -> Bool {
        session.dialRace === self && entries.contains { $0.wire === session.wire }
    }

    private func win(_ index: Int, in session: MacSession) {
        isDecided = true
        startLater?.cancel()
        queued = nil
        let winner = entries[index]
        self.winner = winner.wire
        for (i, entry) in entries.enumerated() where i != index {
            entry.wire.disconnect()
            // A relay that ran out of allowance is worth the user knowing even when the LAN won.
            if entry.buffer.contains(where: { if case .relayQuotaExceeded = $0 { true } else { false } }) {
                session.apply(.relayQuotaExceeded)
            }
        }
        session.wire = winner.wire
        session.connectionPath = winner.path
        session.autoQualityPolicy = AutoQualityPolicy(path: session.autoQualityPath)
        winner.wire.videoFallbackEnabled = winner.path != .lan
        session.dialRace = nil
        for event in winner.buffer { session.apply(event) }
        winner.gate.admit(into: session.renderer)
    }

    func cancel() {
        isDecided = true
        startLater?.cancel()
        queued = nil
        for entry in entries { entry.wire.disconnect() }
        if session?.dialRace === self { session?.dialRace = nil }
    }
}
