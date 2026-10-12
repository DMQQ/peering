import CryptoKit
import Foundation
import MacCastKit
import Network
import RemoteCore
import Security
import os

extension HostSession {
    func handle(_ frame: Frame) {
        // Stamped for every frame rather than only pings: liveness is "anything at all arrived",
        // and a client sending video requests but no pings is no more present than a silent one.
        lastHeard = DispatchTime.now()
        do {
            try route(frame)
        } catch {
            Analytics.failed(error, in: .network)
            fail(error)
        }
    }

    func route(_ frame: Frame) throws {
        switch state {
        case .awaitingRole:
            try handleRole(frame)
        case .awaitingHello:
            try handleClientHello(frame)
        case .awaitingClientCommit:
            try handleClientCommit(frame)
        case .awaitingClientReveal:
            try handleClientReveal(frame)
        case .awaitingConfirmation:
            try handlePairConfirm(frame)
        case .awaitingApproval:
            break
        case .ready:
            try handleCommand(frame)
        case .failed:
            break
        }
    }

    func handleRole(_ frame: Frame) throws {
        guard frame.kind == .connectionRole else {
            throw SessionError.unexpectedFirstFrame(frame.kind)
        }
        guard let role = frame.payload.first.flatMap(ConnectionRole.init(rawValue:)) else {
            throw SessionError.unexpectedFirstFrame(frame.kind)
        }

        switch role {
        case .control:
            state = .awaitingHello
        case .video:
            // Opened after the control connection is authenticated, but a separate socket that
            // carries no handshake of its own: it is handed to the video pipeline, which verifies
            // that an authenticated control session exists for the same peer key. Parked at
            // `.failed` so the control state machine cannot read the next frame as a hello.
            state = .failed
            isVideoConnection = true
            onVideoConnection?(connection)
        }
    }

    func handleClientHello(_ frame: Frame) throws {
        guard frame.kind == .clientHello else { throw SessionError.unexpectedMessage(frame.kind) }
        guard frame.payload.count <= Self.maxControlPayload else {
            throw SessionError.malformedPayload(.clientHello, SessionError.protocolMismatch(client: 0, host: 0))
        }
        let hello = try decode(ClientHello.self, from: frame, as: .clientHello)

        guard hello.protocolVersion == ProtocolInfo.version else {
            throw SessionError.protocolMismatch(client: hello.protocolVersion, host: ProtocolInfo.version)
        }

        guard hello.clientID.utf8.count <= 256, hello.clientName.utf8.count <= 256 else {
            throw SessionError.malformedPayload(.clientHello, SessionError.protocolMismatch(client: 0, host: 0))
        }

        // The peer's key comes from the TLS certificate, never from the message: a client that
        // could declare its own public key would make pinning pointless.
        guard let presentedKey = connection.peerPublicKey else { throw SessionError.noPeerCertificate }

        clientID = hello.clientID
        clientName = hello.clientName
        peerPublicKey = presentedKey
        // Read here, not assumed: both ends speak the same protocol version, so this flag is the
        // only thing that tells a client too old to read a picture apart from one that can.
        clientSupportsClipboardImages = hello.supportsClipboardImages
        clientSupportsTextFocus = hello.supportsTextFocus
        clientSupportsFieldState = hello.supportsFieldState
        clientSupportsPointerReport = hello.supportsPointerReport
        clientSupportsAgentChat = hello.supportsAgentChat
        clientSupportsAgentPermissionModes = hello.supportsAgentPermissionModes
        clientSupportsAgentUsage = hello.supportsAgentUsage
        onVideoCodecsDeclared?(hello.videoCodecs)

        let existingPin = pins.pin(for: clientID)
        if let existingPin, !SPKI.matches(existingPin, presentedKey) {
            throw SessionError.clientKeyMismatch(clientID: clientID)
        }

        // Announced only after the key check: a client that fails it must not appear in the session
        // list, because the disconnect that follows would name a device the UI never showed.
        announced = true
        HostTelemetry.sessionOpened(clientID: clientID, sessionRef: hello.sessionRef, clientPlatform: hello.clientPlatform, viaRelay: arrivedThroughRelay)
        emit(.clientConnected(
            clientID: clientID,
            clientName: clientName,
            viaRelay: arrivedThroughRelay,
            detail: "\(connection.negotiatedTLSVersion) · \(presentedKey.count)-byte key"
        ))

        let alreadyPaired = ClientHello.hostTreatsAsPaired(clientKeyIsPinned: existingPin != nil, lostPairing: hello.lostPairing)
        send(.serverHello, ServerHello(
            serverID: device.id,
            hostName: device.name,
            protocolVersion: ProtocolInfo.version,
            alreadyPaired: alreadyPaired,
            // Hardware addresses are useful only to trusted clients for Wake-on-LAN, and the
            // server hello precedes first-pairing confirmation: exposing them here would let any
            // device on the LAN collect them without being accepted.
            macAddresses: alreadyPaired ? NetworkInterfaceInfo.hardwareMACAddresses() : nil,
            // Declared to everyone, trusted or not: this is the version of this Mac's software,
            // not anything about the user. A client that sends the pause command to a Mac which
            // has not said this gets a decode failure mid-session instead of honest degradation.
            supportsVideoPause: true,
            supportsClipboardImages: true,
            // Same terms again: a client that has not seen this may not send a mosaic, because the
            // request is a capture source an older Mac cannot decode.
            supportsMosaic: true,
            supportsSourceThumbnails: true,
            // Same terms once more: a virtual display rotates only for a client that has said it
            // will report its orientation, so an older phone gets the display shape it always had.
            supportsDeviceOrientation: true,
            // Not an unconditional `true` like the flags above: this one names whether the Mac's
            // system software has the private API at all, not just whether this build understands
            // the command, so a Mac that could never make a display does not advertise a row that
            // can only fail.
            supportsVirtualDisplayManagement: VirtualDisplay.isAvailable,
            pushesTerminalAlertsWhileConnected: true,
            supportsAgentList: true,
            // The other half of the pair: this Mac can run a chat with an installed coding agent,
            // and the phone asks only after reading this.
            supportsAgentChat: true,
            supportsFileBrowser: true,
            supportsAgentModelPicker: true,
            // Which agents, since the set grows and a phone cannot guess it from the version.
            agentChatAgents: AgentSessionManager.chatAgents.keys.sorted(),
            supportsAgentPermissionModes: true,
            supportsAgentUsage: true,
            supportsAgentSessionImport: true,
            supportsAgentPause: true,
            supportsClientState: true,
            supportsLiveActivityPush: true,
            hostPlatform: "macos"
        ))
        if alreadyPaired, let source = hello.resumeSource {
            onCommand?(.setCaptureSource(source))
        }

        if alreadyPaired {
            becomeReady()
            return
        }
        try beginPairing()
    }

    /// Starts the commitment exchange. The commitment exists because without it an active attacker
    /// can grind a keypair until its own contribution reproduces the digits this host is about to
    /// put on screen. See ``PairingSAS``.
    func beginPairing() throws {
        if let refusal = claimPairingPrompt?() {
            refusePairing(refusal)
            return
        }
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let nonce = try Self.randomBytes(32)

        localEphemeral = ephemeral
        localNonce = nonce

        let commitment = PairingSAS.commitment(
            ephemeralPublicKey: ephemeral.publicKey.x963Representation,
            nonce: nonce
        )
        send(.pairCommit, PairingCommit(commitment: commitment))
        state = .awaitingClientCommit
    }

    func handleClientCommit(_ frame: Frame) throws {
        guard frame.kind == .pairCommit else { throw SessionError.unexpectedMessage(frame.kind) }
        guard frame.payload.count <= Self.maxControlPayload else {
            throw SessionError.malformedPayload(.pairCommit, SessionError.protocolMismatch(client: 0, host: 0))
        }
        let commit = try decode(PairingCommit.self, from: frame, as: .pairCommit)
        remoteCommitment = commit.commitment

        // Only now, having committed to our own value, do we reveal it.
        guard let ephemeral = localEphemeral, let nonce = localNonce else {
            throw SessionError.unexpectedMessage(frame.kind)
        }
        send(.pairReveal, PairingReveal(
            ephemeralPublicKey: ephemeral.publicKey.x963Representation,
            nonce: nonce
        ))
        state = .awaitingClientReveal
    }

    func handleClientReveal(_ frame: Frame) throws {
        guard frame.kind == .pairReveal else { throw SessionError.unexpectedMessage(frame.kind) }
        guard frame.payload.count <= Self.maxControlPayload else {
            throw SessionError.malformedPayload(.pairReveal, SessionError.protocolMismatch(client: 0, host: 0))
        }
        let reveal = try decode(PairingReveal.self, from: frame, as: .pairReveal)

        guard let commitment = remoteCommitment,
              PairingSAS.verify(
                  commitment: commitment,
                  ephemeralPublicKey: reveal.ephemeralPublicKey,
                  nonce: reveal.nonce
              )
        else {
            throw SessionError.commitmentMismatch
        }

        remoteEphemeralPublicKey = reveal.ephemeralPublicKey
        remoteNonce = reveal.nonce

        let transcript = PairingTranscript(
            protocolVersion: ProtocolInfo.version,
            clientID: clientID,
            serverID: device.id,
            clientEphemeralPublicKey: reveal.ephemeralPublicKey,
            serverEphemeralPublicKey: localEphemeral?.publicKey.x963Representation ?? Data(),
            clientNonce: reveal.nonce,
            serverNonce: localNonce ?? Data(),
            serverIdentityPublicKey: identity.publicKeyBytes
        )

        pairingTranscript = transcript
        pairingSecret = try Self.randomBytes(16)
        emit(.pairingCode(
            sessionID: id,
            code: PairingSAS.code(for: transcript),
            secret: pairingSecret,
            clientName: clientName,
            isRemote: arrivedThroughRelay
        ))
        state = .awaitingConfirmation
    }

    func handlePairConfirm(_ frame: Frame) throws {
        guard frame.kind == .pairConfirm else { throw SessionError.unexpectedMessage(frame.kind) }
        guard frame.payload.count <= Self.maxControlPayload else {
            throw SessionError.malformedPayload(.pairConfirm, SessionError.protocolMismatch(client: 0, host: 0))
        }
        let confirm = try decode(PairConfirm.self, from: frame, as: .pairConfirm)

        guard confirm.accepted, let peerPublicKey else {
            HostTelemetry.pairingRefused(stage: .confirm)
            rejectPairing(reason: "The codes did not match.")
            return
        }

        if let proof = confirm.proof {
            guard let transcript = pairingTranscript,
                  PairingSAS.verifyProof(proof, secret: pairingSecret, transcript: transcript)
            else {
                HostTelemetry.pairingRefused(stage: .proof)
                rejectPairing(reason: "The pairing code was not accepted.")
                return
            }
            finishPairing(peerPublicKey: peerPublicKey)
        } else {
            // Digits typed by hand prove nothing: they can be computed from the handshake by anyone.
            state = .awaitingApproval
            emit(.pairingNeedsApproval(sessionID: id, clientName: clientName))
        }
    }

    /// The Mac user's answer for a pairing that arrived without the QR secret.
    func resolveApproval(approved: Bool) {
        guard state == .awaitingApproval, let peerPublicKey, approved else {
            if state == .awaitingApproval { HostTelemetry.pairingRefused(stage: .approval); rejectPairing(reason: "The pairing was declined on the Mac.") }
            return
        }
        finishPairing(peerPublicKey: peerPublicKey)
    }

    /// Ends a pairing this Mac's user did not get to see: the prompt is taken, or too many have been asked for.
    private func refusePairing(_ refusal: PairingGate.Refusal) {
        let reason: String
        switch refusal {
        case .anotherPairingInProgress: reason = "Another device is pairing with this Mac right now. Try again in a minute."
        case .tooManyAttempts: reason = "Too many pairing attempts. Try again in a minute."
        }
        hostSessionLog.notice("refused a pairing attempt: \(String(describing: refusal), privacy: .public)")
        send(.pairResult, PairResult(accepted: false, reason: reason))
        state = .failed
        connection.cancel()
    }

    private func rejectPairing(reason: String) {
        send(.pairResult, PairResult(accepted: false, reason: reason))
        _ = releasePairingPrompt?()
        emit(.pairingCompleted(sessionID: id, clientName: clientName, accepted: false))
        state = .failed
        connection.cancel()
    }

    private func finishPairing(peerPublicKey: Data) {
        guard pins.record(peerID: clientID, publicKey: peerPublicKey) else {
            // Reporting success would tell the user they are paired while the next connection
            // silently fails, so the write result is checked rather than assumed.
            HostTelemetry.pairingRefused(stage: .save)
            rejectPairing(reason: "Could not save the pairing.")
            return
        }

        send(.pairResult, PairResult(accepted: true))
        _ = releasePairingPrompt?()
        emit(.pairingCompleted(sessionID: id, clientName: clientName, accepted: true))
        becomeReady()
    }

    /// Lifts the small frame cap that applies until the peer is known, then tells the server.
    private func becomeReady() {
        connection.limitFrames(to: nil)
        state = .ready
        onAuthorized?(connection)
    }
}
