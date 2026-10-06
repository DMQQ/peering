import CryptoKit
import Foundation
import Network
import RemoteCore
import Security
import os

/// The session's own log, file-private like every other one in the host. See ``AGENTS.md`` on
/// `/usr/bin/log`: zsh's builtin shadows it and the queries silently return nothing.
private let sessionLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

final class HostSession: @unchecked Sendable {
    /// The largest payload we will accept on the control channel. Commands and catalogs are
    /// small; anything approaching this is a bug or an attack.
    private static let maxControlPayload = ProtocolInfo.maxControlPayload

    private enum State {
        case awaitingRole
        case awaitingHello
        case awaitingClientCommit
        case awaitingClientReveal
        case awaitingConfirmation
        case ready
        case failed
    }

    enum SessionError: LocalizedError {
        case unexpectedFirstFrame(MessageKind)
        case unexpectedMessage(MessageKind)
        case protocolMismatch(client: UInt16, host: UInt16)
        case malformedPayload(MessageKind, any Error)
        case clientKeyMismatch(clientID: String)
        case commitmentMismatch
        case noPeerCertificate
        case randomFailure

        var errorDescription: String? {
            switch self {
            case .unexpectedFirstFrame(let kind):
                return "Expected a connection-role frame first, got \(kind)."
            case .unexpectedMessage(let kind):
                return "Received \(kind) at this point in the handshake."
            case .protocolMismatch(let client, let host):
                return "Client speaks protocol v\(client), this host speaks v\(host)."
            case .malformedPayload(let kind, let error):
                return "Malformed \(kind) payload: \(error)"
            case .clientKeyMismatch(let clientID):
                return "A client claiming to be \(clientID) presented a different key."
            case .commitmentMismatch:
                return "Pairing commitment did not match the revealed value."
            case .noPeerCertificate:
                return "Peer presented no certificate, so it cannot be identified."
            case .randomFailure:
                return "Could not obtain secure random bytes."
            }
        }
    }

    private let connection: PeerConnection
    private let identity: SelfSignedIdentity
    private let device: DeviceIdentity
    private let pins: PinStore
    private let emit: @Sendable (HostEvent) -> Void

    /// Whether this connection arrived through the relay rather than from this network.
    private let arrivedThroughRelay: Bool

    var onCommand: (@Sendable (RemoteCommand) -> Void)?
    var onVideoConnection: (@Sendable (PeerConnection) -> Void)?
    /// Used by relayed sessions that temporarily carry video on the control stream. Invoked only
    /// after the same pin/SAS authorization required by a normal video connection.
    var onAuthorized: (@Sendable (PeerConnection) -> Void)?
    /// Called when an authorized client asks for video to move between transports.
    var onVideoTransportRequest: (@Sendable (VideoTransportRequest) -> Void)?
    /// Called when an authorized client asks for the secret that seals video datagrams.
    var onVideoKeyRequest: (@Sendable () -> Data?)?

    var onVideoEnabled: (@Sendable (Bool) -> Void)?

    /// Called when the client requests the clipboard. Return `nil` to send nothing.
    var onRequestClipboard: (@Sendable () -> ClipboardPayload?)?
    var onReceiveClipboard: (@Sendable (ClipboardPayload) -> Void)?
    /// Terminal requests are routed only after this session reaches the authenticated state.
    var onTerminalRequest: (@Sendable (TerminalRequest, @escaping @Sendable (TerminalEvent) -> Void) -> Void)?
    var onAgentRequest: (@Sendable (AgentRequest, @escaping @Sendable (AgentEvent) -> Void) -> Void)?

    private var state: State = .awaitingRole
    private(set) var clientID = ""
    private var clientName = "Unknown device"
    private(set) var peerPublicKey: Data?
    /// Whether `.clientConnected` has been emitted, so a disconnect is only ever reported
    /// for a connection the UI was told about in the first place.
    private var announced = false

    /// Pieces of one oversized payload from the client, put back as they arrive.
    private var clipboardChunks = ClipboardTransfer.reassembler()
    private var clipboardFrameID: UInt32 = 0
    private var clientSupportsClipboardImages: Bool?
    private var clientSupportsTextFocus: Bool?
    private var clientSupportsFieldState: Bool?
    private var clientSupportsAgentChat: Bool?
    private var clientSupportsAgentPermissionModes: Bool?

    /// When the last frame arrived from this client, and what stops a session outliving its peer.
    private var lastHeard = DispatchTime.now()

    /// Seconds since anything arrived from this client.
    var silence: TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - lastHeard.uptimeNanoseconds) / 1_000_000_000
    }

    private var closedByHost = false

    // Pairing ephemerals. Generated per attempt, never persisted: they exist only to contribute
    // entropy the other side cannot predict.
    private var localEphemeral: P256.KeyAgreement.PrivateKey?
    private var localNonce: Data?
    private var remoteCommitment: Data?
    private var remoteEphemeralPublicKey: Data?
    private var remoteNonce: Data?

    init(
        connection: PeerConnection,
        identity: SelfSignedIdentity,
        device: DeviceIdentity,
        pins: PinStore,
        arrivedThroughRelay: Bool,
        emit: @escaping @Sendable (HostEvent) -> Void
    ) {
        self.connection = connection
        self.identity = identity
        self.device = device
        self.pins = pins
        self.arrivedThroughRelay = arrivedThroughRelay
        self.emit = emit
    }

    func start() {
        connection.onFrame = { [weak self] frame in
            self?.handle(frame)
        }
        connection.onClose = { [weak self] error in
            guard let self else { return }

            // Runs on the same serial queue as `handle`, so `state` is safe to read here. A close
            // that follows our own `fail` carries no new information, and the "Operation canceled"
            // it produces would read in the UI as a second, unrelated problem.
            if let error, state != .failed, !closedByHost {
                emit(.failed("Connection ended: \(error.localizedDescription)"))
            }

            // Only for a connection that was announced, or a client failing during TLS or before
            // its hello produces "Unknown device disconnected" for a device never seen to arrive.
            if announced {
                emit(.clientDisconnected(clientID: clientID, clientName: clientName))
            }

            onEnded?()
        }
        connection.start()
    }

    func cancel() {
        closedByHost = true
        connection.cancel()
    }

    /// Tells the client hosting stopped, then closes, so it does not mistake this for a drop.
    func endBecauseHostStopped() {
        closedByHost = true
        let notice = ErrorPayload(code: ErrorPayload.hostStoppedCode, message: "Hosting stopped on this Mac.")
        guard let payload = try? MessageCodec.encode(notice) else {
            connection.cancel()
            return
        }
        connection.send(FrameEncoder.encode(Frame(kind: .error, payload: payload))) { [connection] _ in
            connection.cancel()
        }
    }

    /// Called once, on the server queue, when this session's connection is gone.
    var onEnded: (@Sendable () -> Void)?

    var isAuthorized: Bool {
        if case .ready = state { return true }
        return false
    }

    /// Whether this connection asked for the video role and was handed to the video pipeline.
    private(set) var isVideoConnection = false

    // MARK: - Messages to the client

    private var lastSentCatalog: CaptureCatalog?

    /// Pushes the capture catalogue, for a client that is in a position to render it.
    func sendCatalog(_ catalog: CaptureCatalog) {
        guard isAuthorized else { return }
        guard catalog != lastSentCatalog else { return }
        lastSentCatalog = catalog
        send(MessageKind.catalog, catalog)
    }

    // MARK: - Message handling

    private func handle(_ frame: Frame) {
        // Stamped for every frame rather than only pings: liveness is "anything at all arrived",
        // and a client sending video requests but no pings is no more present than a silent one.
        lastHeard = DispatchTime.now()
        do {
            try route(frame)
        } catch {
            fail(error)
        }
    }

    private func route(_ frame: Frame) throws {
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

    private func handleRole(_ frame: Frame) throws {
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

    private func handleClientHello(_ frame: Frame) throws {
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
            supportsAgentPermissionModes: true
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

    // MARK: - Pairing

    /// Starts the commitment exchange. The commitment exists because without it an active attacker
    /// can grind a keypair until its own contribution reproduces the digits this host is about to
    /// put on screen. See ``PairingSAS``.
    private func beginPairing() throws {
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

    private func handleClientCommit(_ frame: Frame) throws {
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

    private func handleClientReveal(_ frame: Frame) throws {
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

    private func handlePairConfirm(_ frame: Frame) throws {
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

    // MARK: - Authenticated commands

    /// - Parameter assembled: whether this frame was put back together from chunks on this end.
    private func handleCommand(_ frame: Frame, assembled: Bool = false) throws {
        switch frame.kind {
        case .command:
            guard assembled || frame.payload.count <= Self.maxControlPayload else {
                throw SessionError.malformedPayload(.command, SessionError.protocolMismatch(client: 0, host: 0))
            }
            let command = try decode(RemoteCommand.self, from: frame, as: .command)
            switch command {
            case .requestClipboard:
                sendClipboard(onRequestClipboard?() ?? .text(""))
            case .pushClipboard(let text):
                onReceiveClipboard?(.text(text))
            case .pushClipboardImage(let png):
                onReceiveClipboard?(.image(png))
            case .setVideoEnabled(let enabled):
                onVideoEnabled?(enabled)
            default:
                onCommand?(command)
            }

        case .videoChunk:
            try handleChunkedPayload(frame)

        case .ping:
            connection.send(Frame(kind: .pong, payload: frame.payload))

        case .terminalRequest:
            guard frame.payload.count <= Self.maxControlPayload else {
                throw SessionError.malformedPayload(.terminalRequest, SessionError.protocolMismatch(client: 0, host: 0))
            }
            let request = try decode(TerminalRequest.self, from: frame, as: .terminalRequest)
            onTerminalRequest?(request) { [weak self] event in
                self?.sendTerminalEvent(event)
            }

        case .agentRequest:
            guard frame.payload.count <= Self.maxControlPayload else {
                throw SessionError.malformedPayload(.agentRequest, SessionError.protocolMismatch(client: 0, host: 0))
            }
            let request = try decode(AgentRequest.self, from: frame, as: .agentRequest)
            onAgentRequest?(request) { [weak self] event in
                self?.sendAgentEvent(event)
            }

        case .videoTransport:
            guard frame.payload.count <= Self.maxControlPayload else {
                throw SessionError.malformedPayload(.videoTransport, SessionError.protocolMismatch(client: 0, host: 0))
            }
            let request = try decode(VideoTransportRequest.self, from: frame, as: .videoTransport)
            onVideoTransportRequest?(request)

        case .videoKeyRequest:
            guard frame.payload.count <= Self.maxControlPayload else {
                throw SessionError.malformedPayload(.videoKeyRequest, SessionError.protocolMismatch(client: 0, host: 0))
            }
            guard let secret = onVideoKeyRequest?() else { return }
            send(MessageKind.videoKey, VideoKeyGrant(secret: secret))

        default:
            throw SessionError.unexpectedMessage(frame.kind)
        }
    }

    func sendTerminalEvent(_ event: TerminalEvent) {
        guard isAuthorized else { return }
        send(.terminalEvent, event)
    }

    /// The restraint is on this side: a chat's events travel to the client that started it, and a
    /// client that has not said it can read an `agentEvent` frame must never be sent one, because
    /// an unknown frame kind ends its session rather than being dropped.
    func sendAgentEvent(_ event: AgentEvent) {
        guard isAuthorized, AgentChatSupport.mayReceive(clientDeclared: clientSupportsAgentChat) else { return }
        // A frame kind an older phone cannot decode ends its session, so it is withheld from one.
        if case .permissionModeChanged = event, clientSupportsAgentPermissionModes != true { return }
        send(.agentEvent, event)
    }

    private func sendClipboard(_ payload: ClipboardPayload) {
        guard isAuthorized else { return }
        if payload.kind == .image, !ClipboardImages.mayReceive(clientDeclared: clientSupportsClipboardImages) {
            sessionLog.notice("not sending a clipboard picture to a client that cannot read one")
            return
        }
        guard let encoded = try? MessageCodec.encode(payload) else { return }
        clipboardFrameID &+= 1
        for frame in ClipboardTransfer.frames(
            kind: .clipboardContent,
            payload: encoded,
            frameID: clipboardFrameID
        ) {
            connection.send(frame)
        }
    }

    /// A payload the client cut up, put back together.
    private func handleChunkedPayload(_ frame: Frame) throws {
        guard let whole = try? clipboardChunks.ingest(frame) else { return }
        try handleCommand(whole, assembled: true)
    }

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, from frame: Frame, as kind: MessageKind) throws -> T {
        do {
            return try MessageCodec.decode(type, from: frame.payload)
        } catch {
            throw SessionError.malformedPayload(kind, error)
        }
    }

    /// Tells the client what stands between it and the picture, or clears what was said.
    ///
    /// Advisory, so it never fails the session: a caption for the frames, not a complaint.
    func sendNotice(_ payload: NoticePayload) {
        guard isAuthorized else { return }
        send(MessageKind.notice, payload)
    }

    func sendTextFocus(_ focus: TextFocus) {
        guard isAuthorized, clientSupportsTextFocus == true else { return }
        send(MessageKind.textFocus, focus)
    }

    func sendFieldState(_ state: FieldState) {
        guard isAuthorized, clientSupportsFieldState == true else { return }
        send(MessageKind.fieldState, state)
    }

    private func send<T: Encodable>(_ kind: MessageKind, _ value: T) {
        guard let payload = try? MessageCodec.encode(value) else {
            fail(SessionError.malformedPayload(kind, SessionError.randomFailure))
            return
        }
        connection.send(Frame(kind: kind, payload: payload))
    }

    private func fail(_ error: any Error) {
        guard state != .failed else { return }
        state = .failed
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        emit(.failed(message))

        // Cancel only once the explanation has been handed to the transport: cancelling right
        // after `send` discards the queued frame and the peer sees a bare disconnect with no
        // reason, which is exactly when the user most needs to know why it was turned away.
        guard let payload = try? MessageCodec.encode(ErrorPayload(code: "session", message: message)) else {
            connection.cancel()
            return
        }
        connection.send(FrameEncoder.encode(Frame(kind: .error, payload: payload))) { [connection] _ in
            connection.cancel()
        }
    }

    private static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw SessionError.randomFailure
        }
        return Data(bytes)
    }
}
