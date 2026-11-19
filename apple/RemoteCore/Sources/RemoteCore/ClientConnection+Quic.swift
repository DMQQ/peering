import Foundation

extension ClientConnection {
    public var isQuic: Bool { quic != nil }

    /// Opens the session over QUIC through the relay's UDP port, with this end's relay token in front of every packet.
    public func connectQuic(
        relay: RelaySession,
        identity: SelfSignedIdentity,
        pinnedServerKey: Data?,
        timeout: TimeInterval
    ) async throws {
        guard let relayAddress = QuicAddress.resolve(host: relay.videoHost, port: relay.videoPort) else {
            throw Failure.transport("The relay's address could not be resolved.")
        }
        try await connectQuic(
            to: relayAddress,
            relay: QuicEndpoint.RelayRoute(address: relayAddress, token: relay.videoToken),
            identity: identity,
            pinnedServerKey: pinnedServerKey,
            timeout: timeout
        )
    }

    /// Opens the session over QUIC to `address`: the Mac itself on the LAN, or the relay when `relay` is given. The Mac's key is checked against `pinnedServerKey` once the handshake shows it.
    public func connectQuic(
        to address: QuicAddress,
        relay: QuicEndpoint.RelayRoute?,
        identity: SelfSignedIdentity,
        pinnedServerKey: Data?,
        timeout: TimeInterval
    ) async throws {
        let configuration = try QuicConfiguration(identity: identity)
        let link = try QuicFrameLink.dial(address, relay: relay, configuration: configuration, label: "pl.dmq.peering.client.quic")
        quic = link
        link.onFrame = { [weak self] frame in
            let handler = self?.lock.withLock { self?._onFrame }
            handler?(frame)
        }
        link.onClose = { [weak self] _ in self?.finish(.hostClosed) }

        let handle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.finishIfOpen(Failure.timedOut(timeout))
        }
        lock.withLock { timeoutTask = handle }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.withLock { readyContinuation = continuation }
            link.onEstablished = { [weak self, weak link] in
                guard let self, let link else { return }
                self.cancelTimeout()
                let presented = link.peerPublicKey
                if let pinnedServerKey, !(presented.map { SPKI.matches($0, pinnedServerKey) } ?? false) {
                    let failure = Failure.transport("The Mac presented a different key from the one this phone paired with.")
                    self.resumeReady(.failure(failure))
                    self.finish(failure)
                    return
                }
                self.lock.withLock {
                    self._observedServerKey = presented
                    self._tlsVersion = "QUIC (TLS 1.3)"
                }
                self.resumeReady(.success(()))
            }
        }
    }
}
