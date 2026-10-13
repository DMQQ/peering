import CryptoKit
import Foundation
import PeeringKit
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

        try checkAcceptable(hello)

        // The peer's key comes from the TLS certificate, never from the message: a client that
        // could declare its own public key would make pinning pointless.
        guard let presentedKey = connection.peerPublicKey else { throw SessionError.noPeerCertificate }

        clientID = hello.clientID
        clientName = hello.clientName
        peerPublicKey = presentedKey
        adoptCapabilities(of: hello)

        let existingPin = pins.pin(for: clientID)
        if let existingPin, !SPKI.matches(existingPin, presentedKey) {
            throw SessionError.clientKeyMismatch(clientID: clientID)
        }

        if let admitsClient, !admitsClient(hello.clientID) { throw SessionError.anotherDeviceConnected }

        // Only after the key check: a client that fails it must not appear in the session
        // list, because the disconnect that follows would name a device the UI never showed.
        announce(hello, presentedKey: presentedKey)

        let alreadyPaired = ClientHello.hostTreatsAsPaired(clientKeyIsPinned: existingPin != nil, lostPairing: hello.lostPairing)
        send(.serverHello, serverHello(alreadyPaired: alreadyPaired))
        if alreadyPaired, let source = hello.resumeSource {
            onCommand?(.setCaptureSource(source))
        }

        if alreadyPaired {
            becomeReady()
            return
        }
        try beginPairing()
    }

    private func checkAcceptable(_ hello: ClientHello) throws {
        guard hello.protocolVersion == ProtocolInfo.version else {
            throw SessionError.protocolMismatch(client: hello.protocolVersion, host: ProtocolInfo.version)
        }
        guard hello.clientID.utf8.count <= 256, hello.clientName.utf8.count <= 256 else {
            throw SessionError.malformedPayload(.clientHello, SessionError.protocolMismatch(client: 0, host: 0))
        }
    }

    private func announce(_ hello: ClientHello, presentedKey: Data) {
        announced = true
        HostTelemetry.sessionOpened(clientID: clientID, sessionRef: hello.sessionRef, clientPlatform: hello.clientPlatform, viaRelay: arrivedThroughRelay)
        emit(.clientConnected(
            clientID: clientID,
            clientName: clientName,
            viaRelay: arrivedThroughRelay,
            detail: "\(connection.negotiatedTLSVersion) · \(presentedKey.count)-byte key"
        ))
    }

    /// Read here, not assumed: both ends speak the same protocol version, so these flags are the
    /// only thing that tells a client too old to read a picture apart from one that can.
    private func adoptCapabilities(of hello: ClientHello) {
        clientSupportsClipboardImages = hello.supportsClipboardImages
        clientSupportsTextFocus = hello.supportsTextFocus
        clientSupportsFieldState = hello.supportsFieldState
        clientSupportsPointerReport = hello.supportsPointerReport
        clientSupportsAgentChat = hello.supportsAgentChat
        clientSupportsAgentPermissionModes = hello.supportsAgentPermissionModes
        clientSupportsAgentUsage = hello.supportsAgentUsage
        onVideoCodecsDeclared?(hello.videoCodecs)
    }

    /// What this Mac says about itself, and which optional features it will answer.
    private func serverHello(alreadyPaired: Bool) -> ServerHello {
        ServerHello(
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
        )
    }
}
