import CryptoKit
import Foundation
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
        clientSupportsAgentChat = hello.supportsAgentChat
        clientSupportsAgentPermissionModes = hello.supportsAgentPermissionModes
        clientSupportsAgentUsage = hello.supportsAgentUsage

        let existingPin = pins.pin(for: clientID)
        if let existingPin, !SPKI.matches(existingPin, presentedKey) {
            throw SessionError.clientKeyMismatch(clientID: clientID)
        }

        // Announced only after the key check: a client that fails it must not appear in the session
        // list, because the disconnect that follows would name a device the UI never showed.
        announced = true
        emit(.clientConnected(
            clientID: clientID,
            clientName: clientName,
            viaRelay: arrivedThroughRelay,
            detail: "\(connection.negotiatedTLSVersion) · \(presentedKey.count)-byte key"
        ))

        let alreadyPaired = existingPin != nil
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
            supportsAgentUsage: true
        ))
        if alreadyPaired, let source = hello.resumeSource {
            onCommand?(.setCaptureSource(source))
        }

        if alreadyPaired {
            state = .ready
            onAuthorized?(connection)
            return
        }
        try beginPairing()
    }

    /// Starts the commitment exchange. The commitment exists because without it an active attacker
    /// can grind a keypair until its own contribution reproduces the digits this host is about to
    /// put on screen. See ``PairingSAS``.
    func beginPairing() throws {
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

        emit(.pairingCode(
            code: PairingSAS.code(for: transcript),
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
            send(.pairResult, PairResult(accepted: false, reason: "The codes did not match."))
            emit(.pairingCompleted(clientName: clientName, accepted: false))
            state = .failed
            connection.cancel()
            return
        }

        guard pins.record(peerID: clientID, publicKey: peerPublicKey) else {
            // Reporting success would tell the user they are paired while the next connection
            // silently fails, so the write result is checked rather than assumed.
            send(.pairResult, PairResult(accepted: false, reason: "Could not save the pairing."))
            emit(.pairingCompleted(clientName: clientName, accepted: false))
            state = .failed
            connection.cancel()
            return
        }

        send(.pairResult, PairResult(accepted: true))
        emit(.pairingCompleted(clientName: clientName, accepted: true))
        state = .ready
        onAuthorized?(connection)
    }
}
