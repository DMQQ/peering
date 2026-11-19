import Foundation

extension ClientSession {
    /// Over QUIC through the relay, tries a path straight to the Mac and moves the whole connection onto it when it opens, and back to the relay when it goes. The session itself never notices.
    func startQuicDirectPath(on connection: ClientConnection, relay: RelaySession) {
        guard let link = connection.quic,
              let relayAddress = QuicAddress.resolve(host: relay.videoHost, port: relay.videoPort)
        else { return }
        let mover = QuicDirectPath(
            link: link,
            relay: relayAddress,
            role: .dialer,
            videoToken: relay.videoToken,
            restarts: { [weak self] in self?.lock.withLock { self?.directPathRestarts } ?? 0 },
            onChange: { [weak self] change in self?.apply(change) }
        )
        let task = Task { await mover.run() }
        let previous = lock.withLock { () -> Task<Void, Never>? in
            defer { directPathTask = task }
            return directPathTask
        }
        previous?.cancel()
    }

    private func apply(_ change: QuicDirectPath.Change) {
        switch change {
        case .report(let outcome):
            reportDirectPath(outcome)
        case .verdictDue:
            reportDirectPath(lock.withLock { reportedDirectPath }.verdict())
        case .onDirect(let direct):
            let path: DatagramPath = direct ? .direct : .relay
            let changed = lock.withLock { () -> Bool in
                guard reportedPath != path else { return false }
                reportedPath = path
                return true
            }
            guard changed else { return }
            emit(.path(path))
            emit(.note(direct ? "The connection moved straight to the Mac." : "The connection moved back to the relay."))
        }
    }
}
