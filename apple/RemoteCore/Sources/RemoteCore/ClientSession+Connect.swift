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
            connectStage = .connecting
            return true
        }
        guard installed else {
            proxy.cancel()
            throw ConnectAttemptEnded()
        }

        if let remaining = allocation.remainingSeconds {
            emit(.relayRemaining(seconds: remaining))
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
            _failureCause = nil
            _failureDiagnosis = nil
            _millisecondsToReady = nil
            connectStartedAt = Self.monotonicNow()
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

extension ClientSession {
    // MARK: - Connect

    /// Runs the client side of the handshake and returns once the outcome is known. Returns rather than throws: every failure already reaches the UI as a ``Phase/failed(_:)`` event.
    public func connect(to target: Target, timeout: TimeInterval = 10) async {
        guard let generation = beginConnecting() else {
            emit(.phase(.failed(Failure.busy.errorDescription ?? "busy")))
            return
        }
        emit(.phase(.connecting))

        let pinned: Data? = {
            if case .discovered(let host) = target { return pins.pin(for: host.id) }
            if case .relay(let hostID, _, _) = target { return pins.pin(for: hostID) }
            // Looked up and not insisted on: a first pairing has no pin; the handshake still checks a stored one.
            if case .relayPairing(let hostID, _, _) = target { return pins.pin(for: hostID) }
            return nil
        }()
        lock.withLock {
            pairingHostID = target.isFirstPairing ? target.hostID : nil
            connectStage = target.startingStage
        }

        let connection = ClientConnection(label: "pl.dmq.peering.client.control")
        connection.onFrame = { [weak self] frame in self?.handle(frame) }
        connection.onClose = { [weak self] failure in self?.controlClosed(failure) }
        let installed = lock.withLock { () -> Bool in
            guard connectGeneration == generation else { return false }
            control = connection
            return true
        }
        guard installed else {
            connection.cancel()
            return
        }

        do {
            switch target {
            case .discovered(let host):
                try await connection.connect(
                    to: host.endpoint,
                    identity: identity,
                    pinnedServerKey: pinned,
                    timeout: timeout
                )
            case .address(let host, let port):
                try await connection.connect(
                    host: host,
                    port: port,
                    identity: identity,
                    pinnedServerKey: nil,
                    timeout: timeout
                )
            case .relay(let hostID, _, let entitlement):
                guard let pin = pins.pin(for: hostID) else {
                    throw pins.isUnreadable ? Failure.pinsUnreadable : Failure.noPinOnFile(hostID: hostID)
                }
                try await openRelayTunnel(
                    to: connection,
                    generation: generation,
                    hostID: hostID,
                    entitlement: entitlement,
                    pinnedServerKey: pin,
                    timeout: timeout
                )

            case .relayPairing(let hostID, _, let entitlement):
                try await openRelayTunnel(
                    to: connection,
                    generation: generation,
                    hostID: hostID,
                    entitlement: entitlement,
                    pinnedServerKey: pinned,
                    timeout: timeout
                )
            }
        } catch {
            // `disconnect()` invalidates the generation before cancelling whatever resources
            // already exist. An older dial returning afterwards is finished, not a new failure
            // belonging to the next session.
            if error is ConnectAttemptEnded || !isCurrentAttempt(connection, generation: generation) {
                connection.cancel()
                return
            }
            if let e = error as? RelaySignallingError,
               case .refused(let code, _) = e, code == "quotaExceeded" {
                emit(.relayQuotaExceeded)
            }
            fail(Failure.describe(error), reason: FailureReason(error), cause: FailureCause(error))
            return
        }

        guard isCurrentAttempt(connection, generation: generation) else {
            connection.cancel()
            return
        }

        lock.withLock { _serverKey = connection.observedServerKey }
        emit(.note("Connected over \(connection.negotiatedTLSVersion)"))

        connection.send(Frame(
            kind: .connectionRole,
            payload: Data([ConnectionRole.control.rawValue])
        ))

        // 2. Say who we are. `wantsPairing` is advisory: the Mac decides, because only the
        //    Mac knows its own pin store.
        let hostID = target.hostID
        let knowsHost = hostID.map { pins.pin(for: $0) != nil } ?? false
        connection.send(.clientHello, ClientHello(
            clientID: clientID,
            clientName: clientName,
            protocolVersion: ProtocolInfo.version,
            wantsPairing: !knowsHost,
            // Declared on every connection: it restrains the Mac, whose picture would otherwise land in a client that cannot read it.
            supportsClipboardImages: true,
            supportsTextFocus: true,
            supportsFieldState: true,
            supportsPointerReport: true,
            supportsAgentChat: true,
            supportsAgentPermissionModes: true,
            supportsAgentUsage: true,
            resumeSource: knowsHost ? resumeSource : nil,
            lostPairing: hostID != nil && !knowsHost ? true : nil,
            takesOver: knowsHost && takesOver ? true : nil,
            sessionRef: sessionRef
        ))

        lock.withLock {
            state = .awaitingServerHello
            _phase = .handshaking
            connectStage = .handshake
        }
        emit(.phase(.handshaking))
        armHandshakeDeadline(generation: generation)
        coalescer.start()
    }


    // MARK: - Pairing

    /// `secret` is the one from the Mac's QR code; digits typed by hand have none, and the Mac then asks its own user.
    public func confirmPairing(accepted: Bool, secret: Data? = nil) {
        lock.lock()
        let canConfirm = state == .awaitingUserConfirmation
        if accepted, canConfirm { state = .awaitingPairResult }
        let transcript = pairingTranscript
        lock.unlock()

        guard canConfirm else { return }
        let proof = secret.flatMap { secret in transcript.map { PairingSAS.proof(secret: secret, transcript: $0) } }
        connection()?.send(.pairConfirm, PairConfirm(accepted: accepted, proof: proof))

        guard accepted else {
            emit(.note("Pairing declined."))
            disconnect()
            return
        }
    }
}
