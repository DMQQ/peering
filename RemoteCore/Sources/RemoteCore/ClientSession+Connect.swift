import CryptoKit
import Crypto
import Foundation
import Network
import Security
import os

extension ClientSession {
    /// Opens the relay's tunnel to a Mac and connects through it. Both relay targets share this; only the pin differs.
    func openRelayTunnel(
        to connection: ClientConnection,
        generation: UInt64,
        hostID: String,
        entitlement: RelayEntitlement,
        pinnedServerKey: Data?,
        timeout: TimeInterval
    ) async throws {
        // Signed here, because this is where the key and the ID are both in hand. A failure to
        // sign is not a failure to connect: the relay falls back to metering the announced ID.
        let clientProof = try? RelayDeviceProof.makeClientProof(clientID: clientID, identity: identity)
        let allocation = try await RelaySignallingConnection.requestSession(
            at: ProtocolInfo.relaySignallingURL,
            hostID: hostID,
            clientID: clientID,
            entitlement: entitlement,
            clientProof: clientProof
        )
        try requireCurrentAttempt(connection, generation: generation)

        let proxy = RelayControlProxy(session: allocation)
        let endpoint: NWEndpoint
        do {
            endpoint = try await proxy.start()
        } catch {
            proxy.cancel()
            throw error
        }

        let installed = lock.withLock { () -> Bool in
            guard connectGeneration == generation, control === connection else { return false }
            relayProxy = proxy
            usesRelayedSingleStream = true
            // Kept because the relay told this end where the Mac's video datagrams
            // will come from and what to bind with, and there is no second chance to
            // ask: the signalling socket is closed the moment the session is returned.
            relaySession = allocation
            return true
        }
        guard installed else {
            proxy.cancel()
            throw ConnectAttemptEnded()
        }

        try await connection.connect(
            to: endpoint,
            identity: identity,
            pinnedServerKey: pinnedServerKey,
            timeout: timeout
        )
        try requireCurrentAttempt(connection, generation: generation)
    }

    /// Claims the session for one connect attempt. Returns `false` if it is already in use,
    /// so a double tap on "Connect" cannot leave two handshakes racing on one object.
    func beginConnecting() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .idle, .failed:
            connectGeneration &+= 1
            state = .idle
            _phase = .connecting
            _failureReason = nil
            return connectGeneration
        default:
            return nil
        }
    }

    struct ConnectAttemptEnded: Error {}

    func isCurrentAttempt(_ connection: ClientConnection, generation: UInt64) -> Bool {
        lock.withLock { connectGeneration == generation && control === connection }
    }

    func requireCurrentAttempt(
        _ connection: ClientConnection,
        generation: UInt64
    ) throws {
        guard isCurrentAttempt(connection, generation: generation) else {
            throw ConnectAttemptEnded()
        }
    }
}
