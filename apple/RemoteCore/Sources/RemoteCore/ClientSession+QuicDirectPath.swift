import Foundation

/// What a session needs to ask the relay for a route to its Mac mid-session.
public struct RelayAccess: Sendable {
    public let hostID: String
    public let entitlement: RelayEntitlement

    public init(hostID: String, entitlement: RelayEntitlement) {
        self.hostID = hostID
        self.entitlement = entitlement
    }
}

extension ClientSession {
    /// Over QUIC through the relay, tries a path straight to the Mac and moves the whole connection onto it when it opens, and back to the relay when it goes. The session itself never notices.
    /// `startsOnRelay` is false for a session that began on the LAN: its link is given the relay route first, and the mover moves it there once that path validates.
    func startQuicDirectPath(on connection: ClientConnection, relay: RelaySession, startsOnRelay: Bool = true) {
        guard let link = connection.quic,
              let relayAddress = QuicAddress.resolve(host: relay.videoHost, port: relay.videoPort)
        else { return }
        if !startsOnRelay { link.useRelay(QuicEndpoint.RelayRoute(address: relayAddress, token: relay.videoToken)) }
        let mover = QuicDirectPath(
            link: link,
            relay: relayAddress,
            role: .dialer,
            videoToken: relay.videoToken,
            startsOnRelay: startsOnRelay,
            restarts: { [weak self] in self?.lock.withLock { self?.directPathRestarts } ?? 0 },
            onChange: { [weak self] change in self?.apply(change) }
        )
        if let announced = lock.withLock({ announcedCandidates }) { mover.announced(announced) }
        let task = Task { await mover.run() }
        let previous = lock.withLock { () -> Task<Void, Never>? in
            quicDirectPath = mover
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
        case .renewRelay:
            carryOverToRelay()
        case .onPath(let path):
            let changed = lock.withLock { () -> Bool in
                guard reportedPath != path else { return false }
                reportedPath = path
                return true
            }
            guard changed else { return }
            emit(.path(path))
            switch path {
            case .relay: emit(.note("The connection moved back to the relay."))
            case .direct: emit(.note("The connection moved straight to the Mac."))
            case .lan: emit(.note("The connection moved to the Mac on this network."))
            }
        }
    }

    /// Where the Mac says it can be reached on its own network: handled in any state, since it may arrive before the handshake is done.
    func handleDirectCandidates(_ frame: Frame) {
        guard let candidates = try? MessageCodec.decode(DirectCandidates.self, from: frame.payload) else { return }
        let mover = lock.withLock { () -> QuicDirectPath? in
            announcedCandidates = candidates
            return quicDirectPath
        }
        mover?.announced(candidates)
    }

    /// How to reach this Mac through the relay, for a session that began on the LAN. Set by the app at dial time; nil when the relay is not allowed.
    public var relayAccess: RelayAccess? {
        get { lock.withLock { _relayAccess } }
        set { lock.withLock { _relayAccess = newValue } }
    }

    public var isOnQuic: Bool { connection()?.isQuic == true }

    /// The phone left the network the session's path was on: asks the relay for a route to the same Mac and moves the connection there, with no new handshake. Without relay access the session is left to its liveness checks, as before.
    func carryOverToRelay() {
        guard let connection = connection(), connection.isQuic else { return }
        let access = lock.withLock { () -> RelayAccess? in
            guard !carryingOver, let access = _relayAccess else { return nil }
            carryingOver = true
            return access
        }
        guard let access else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { lock.withLock { carryingOver = false } }
            let proof = try? RelayDeviceProof.makeClientProof(clientID: clientID, identity: identity)
            let allocation: RelaySession
            do {
                allocation = try await RelaySignallingConnection.requestSession(
                    at: ProtocolInfo.relaySignallingURL,
                    hostID: access.hostID,
                    clientID: clientID,
                    entitlement: access.entitlement,
                    clientProof: proof
                )
            } catch {
                clientSessionLog.error("could not carry the session onto the relay: \(String(describing: error), privacy: .public)")
                return
            }
            guard self.connection() === connection else { return }
            lock.withLock { relaySession = allocation }
            if let remaining = allocation.remainingSeconds { emit(.relayRemaining(seconds: remaining)) }
            clientSessionLog.notice("carrying the session onto the relay")
            startQuicDirectPath(on: connection, relay: allocation, startsOnRelay: false)
        }
    }
}
