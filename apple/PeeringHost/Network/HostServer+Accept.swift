import Foundation
import PeeringKit
import Network
import RemoteCore
import os

private let videoLog = Logger(subsystem: "pl.dmq.peering.host", category: "video")

extension HostServer {
    /// A callback for `session` that does nothing once the server or the session is gone, so neither is kept alive by the other's closure.
    func bind<each Input>(
        to session: HostSession,
        _ body: @escaping @Sendable (HostServer, HostSession, repeat each Input) -> Void
    ) -> @Sendable (repeat each Input) -> Void {
        { [weak self, weak session] (input: repeat each Input) in
            guard let self, let session else { return }
            body(self, session, repeat each input)
        }
    }

    func accept(_ connection: NWConnection) {
        let origin = ConnectionOrigin(connection)
        let tunnel = connections.claimTunnel(loopbackPort: origin.loopbackPort, now: .now)
        let address = tunnel.map { "relay-\($0.id)" } ?? origin.address
        guard admitBeforeAuthentication(address: address) else {
            connection.cancel()
            tunnel?.bridge.cancel()
            return
        }
        let peer = PeerConnection(connection: connection, queue: queue)
        let session = HostSession(
            connection: peer,
            identity: identity,
            device: device,
            pins: pins,
            // A relayed connection reaches this same `accept` through the loopback bridge, so
            // the pending allocation is the only thing that knows where it came from.
            arrivedThroughRelay: tunnel != nil,
            address: address,
            emit: { [weak self] event in self?.emit(event) }
        )
        installRequestHandlers(on: session)
        installPairingPrompt(on: session, address: address)
        session.admitsClient = { [weak self, weak session] clientID in
            guard let self, let session else { return false }
            return admitDevice(clientID: clientID, joining: session)
        }
        installVideoHandlers(on: session, peer: peer, tunnel: tunnel)
        installLifecycleHandlers(on: session, relayBridge: tunnel?.bridge)
        connections.add(session)
        session.start()
    }

    /// Routes what a phone asks for to the part of the host that answers it.
    private func installRequestHandlers(on session: HostSession) {
        session.onCommand = { [weak self] command in
            self?.callbacks.onCommand?(command)
        }
        session.onRequestClipboard = { [weak self] reply in
            guard let handler = self?.callbacks.onRequestClipboard else { return reply(nil) }
            handler(reply)
        }
        session.onReceiveClipboard = { [weak self] payload, done in
            guard let handler = self?.callbacks.onReceiveClipboard else { return done() }
            handler(payload, done)
        }
        session.onTerminalRequest = bind(to: session) { server, session, request, sink in
            server.terminalManager.handle(clientID: session.clientID, request: request, sink: sink)
        }
        session.onBackPressure = bind(to: session) { server, session, backedUp in
            server.terminalManager.setOutputPaused(backedUp, clientID: session.clientID)
            server.agentManager.setOutputPaused(backedUp, clientID: session.clientID)
        }
        session.onAgentRequest = bind(to: session) { server, session, request, sink in
            server.agentManager.handle(clientID: session.clientID, request: request, sink: sink)
        }
        session.onPreviewRequest = bind(to: session) { server, session, command, sink in
            server.previewProxy.handle(clientID: session.clientID, command: command, sink: sink)
        }
        session.onClientBackground = bind(to: session) { server, session, background in
            server.presence.backgroundChanged(clientID: session.clientID, session: session.sessionID, background: background)
            server.activityPublisher.changed(clientID: session.clientID)
        }
        session.onActivityToken = bind(to: session) { server, session, tokens in
            server.activityPublisher.tokens(clientID: session.clientID, tokens)
        }
    }

    private func installVideoHandlers(on session: HostSession, peer: PeerConnection, tunnel: HostConnections.RelayTunnel?) {
        session.onVideoTransportRequest = bind(to: session) { server, session, request in
            server.callbacks.onVideoTransport?(session.peerPublicKey, request, peer)
        }
        session.onVideoEnabled = bind(to: session) { server, session, enabled in
            server.callbacks.onVideoEnabled?(session.peerPublicKey, enabled)
        }
        session.onVideoCodecsDeclared = bind(to: session) { server, session, codecs in
            server.callbacks.onClientVideoCodecs?(session.peerPublicKey, codecs)
        }
        // Only a session that arrived through the relay has anywhere to send datagrams, and the
        // allocation that says where came in with it. A direct session gets the same silence as a
        // client that is not being served: it has its own video connection.
        if let relaySession = tunnel?.session {
            session.onVideoKeyRequest = { [weak self, weak session] in
                guard let self, let session else { return nil }
                return callbacks.onVideoKeyRequest?(session.peerPublicKey, relaySession)
            }
        }
        session.onVideoConnection = { [weak self] videoPeer in
            self?.videoConnectionArrived(videoPeer)
        }
    }

    private func installLifecycleHandlers(on session: HostSession, relayBridge: RelayControlBridge?) {
        // Set for every session, not only relayed ones: this is both the moment the advertisement
        // is withdrawn and the moment a relayed video connection is handed over.
        session.onAuthorized = bind(to: session) { server, session, controlPeer in
            server.presence.connected(clientID: session.clientID, session: session.sessionID)
            server.activityPublisher.sessionBegan(clientID: session.clientID, viaRelay: relayBridge != nil)
            server.updateAdvertisement()
            // The remote transport multiplexes encoded video onto this same TLS stream; it is the
            // same authenticated connection as control, and the relay still cannot read it.
            if relayBridge != nil { server.callbacks.onVideoConnection?(controlPeer) }
        }
        // Strong in `session`: a session removed from the table while it closes must still be around to report its end.
        session.onEnded = { [weak self] in
            self?.sessionEnded(session, relayBridge: relayBridge)
        }
    }

    /// A video connection carries no handshake of its own, so it is accepted only when an authorized control session holds the same key.
    private func videoConnectionArrived(_ videoPeer: PeerConnection) {
        guard let key = videoPeer.peerPublicKey, connections.isAuthorized(key: key) else {
            // This is the only thing authorizing a video connection. Such a connection
            // carries no handshake of its own and does not say which client it belongs to,
            // and the TLS verify block accepts any self-signed chain (authenticity comes from
            // pairing, not a CA), so completing a TLS handshake proves nothing.
            videoLog.notice("refused a video connection with no authorized control session")
            emit(.failed("Refused a video connection from an unauthorized client"))
            videoPeer.cancel()
            return
        }
        videoPeer.limitFrames(to: nil)
        connections.add(video: videoPeer, clientKey: key)
        let previousClose = videoPeer.onClose
        videoPeer.onClose = { [weak self, weak videoPeer] error in
            previousClose?(error)
            guard let self, let videoPeer else { return }
            connections.remove(video: videoPeer)
        }
        callbacks.onVideoConnection?(videoPeer)
    }

    private func sessionEnded(_ session: HostSession, relayBridge: RelayControlBridge?) {
        connections.remove(session)
        presence.disconnected(clientID: session.clientID, session: session.sessionID)
        releaseHeldInput(of: session)
        if connections.authorizedCount(clientID: session.clientID) == 0 {
            if session.isAuthorized {
                activityPublisher.sessionEnded(clientID: session.clientID, byHost: session.closedByHost && !session.endedForSilence)
            }
            terminalManager.disconnect(clientID: session.clientID)
            agentManager.disconnect(clientID: session.clientID)
            previewProxy.disconnect(clientID: session.clientID)
        }
        // And the streams it authorized end with it: a video connection that outlived its
        // control session would keep delivering the screen to a client the host believes is
        // gone.
        if !session.isVideoConnection, !connections.isAuthorized(key: session.peerPublicKey) {
            closeVideoConnections(for: session.peerPublicKey)
            callbacks.onClientVideoCodecs?(session.peerPublicKey, nil)
        }
        updateAdvertisement()
        if let relayBridge {
            relayBridge.cancel()
            connections.releaseActiveTunnel(bridge: relayBridge)
        }
    }

    private func closeVideoConnections(for clientKey: Data?) {
        guard let clientKey else { return }
        for peer in connections.takeVideo(clientKey: clientKey) { peer.cancel() }
    }
}
