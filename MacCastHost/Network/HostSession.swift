import CryptoKit
import Foundation
import Network
import RemoteCore
import Security
import os

/// The session's own log, file-private like every other one in the host. See ``AGENTS.md`` on
/// `/usr/bin/log`: zsh's builtin shadows it and the queries silently return nothing.
private let sessionLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

/// Drives one connection from its first frame to a usable session.
///
/// All state is mutated on the server's serial queue, which is also the connection's queue, so
/// no locking is needed here.
final class HostSession: @unchecked Sendable {
    /// The largest payload we will accept on the control channel. Commands and catalogs are
    /// small; anything approaching this is a bug or an attack.
    ///
    /// Shared rather than repeated, because it is the number the video fallback cuts its
    /// chunks to fit under.
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
    ///
    /// The session's behaviour does not depend on it (TLS and the handshake are the same either
    /// way) but the user's does: a relayed pairing prompt is asking someone at this Mac to compare
    /// digits with a person who is not in the room.
    private let arrivedThroughRelay: Bool

    /// Invoked once the session is authenticated and may carry commands.
    var onCommand: (@Sendable (RemoteCommand) -> Void)?
    /// Invoked with the video connection once a client opens one.
    var onVideoConnection: (@Sendable (PeerConnection) -> Void)?
    /// Used by relayed sessions that temporarily carry video on the control stream. Invoked only
    /// after the same pin/SAS authorization required by a normal video connection.
    var onAuthorized: (@Sendable (PeerConnection) -> Void)?
    /// Called when an authorized client asks for video to move between transports.
    ///
    /// Routed out rather than decided here: a session knows only its own connection, while the
    /// answer needs the video pipeline and the peer being served. The server has both.
    var onVideoTransportRequest: (@Sendable (VideoTransportRequest) -> Void)?
    /// Called when an authorized client asks for the secret that seals video datagrams.
    ///
    /// Answers the secret, or `nil` for a refusal, and a refusal is silence rather than an error:
    /// a Mac that does not answer is still sending the picture down the stream this session
    /// already has. The server holds the relay's allocation and the pipeline, which a session
    /// does not.
    var onVideoKeyRequest: (@Sendable () -> Data?)?

    /// Called when a client asks for the picture to be turned on or off. See
    /// ``RemoteCommand/setVideoEnabled(_:)``.
    ///
    /// Carries the request and nothing else; the connection to act on is found from the key this
    /// session presented, which the server adds on the way out. Same division as
    /// ``onVideoTransportRequest``: a session knows one connection, the answer needs whichever
    /// connection is being served now.
    var onVideoEnabled: (@Sendable (Bool) -> Void)?

    /// Called when the client requests the clipboard. Return `nil` to send nothing.
    ///
    /// A payload rather than a string, because the pasteboard may be holding a picture and only
    /// this end can find that out.
    var onRequestClipboard: (@Sendable () -> ClipboardPayload?)?
    /// Called when the client pushes its clipboard to the host.
    var onReceiveClipboard: (@Sendable (ClipboardPayload) -> Void)?
    /// Terminal requests are routed only after this session reaches the authenticated state.
    var onTerminalRequest: (@Sendable (TerminalRequest, @escaping @Sendable (TerminalEvent) -> Void) -> Void)?

    private var state: State = .awaitingRole
    private(set) var clientID = ""
    private var clientName = "Unknown device"
    /// Readable so the server can match a video connection to the control session that
    /// authorizes it. Both are on the same serial queue, so no lock is needed.
    private(set) var peerPublicKey: Data?
    /// Whether `.clientConnected` has been emitted, so a disconnect is only ever reported
    /// for a connection the UI was told about in the first place.
    private var announced = false

    /// Pieces of one oversized payload from the client, put back as they arrive.
    ///
    /// The only assembler this end has, unlike the client's two: a picture's chunks travel host to
    /// client and never the other way, so the only thing a client ever cuts up for the host is a
    /// command with a screenshot in it.
    private var clipboardChunks = ClipboardTransfer.reassembler()
    /// Which clipboard payload is being cut up on the way out, so the client can tell two apart.
    private var clipboardFrameID: UInt32 = 0
    /// What the client said about reading a picture, off its hello. `nil` is a client built before
    /// the field existed, which is a no.
    private var clientSupportsClipboardImages: Bool?
    /// Whether the client can decode ``MessageKind/textFocus``. `nil` is a client built before it.
    private var clientSupportsTextFocus: Bool?
    private var clientSupportsFieldState: Bool?

    /// When the last frame arrived from this client, and what stops a session outliving its peer.
    ///
    /// The client pings once a second, so silence here is evidence rather than an inference. It is
    /// needed because TCP does not reliably report a peer that is gone: a phone killed while the
    /// network moved on sends no FIN, and the host would hold a session that is still authorized,
    /// still suppresses the Bonjour advertisement, and is still shown as connected.
    ///
    /// Written in ``handle(_:)``, read by the server's reaper, both on the server's serial queue.
    private var lastHeard = DispatchTime.now()

    /// Seconds since anything arrived from this client.
    var silence: TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - lastHeard.uptimeNanoseconds) / 1_000_000_000
    }

    /// Set when *we* end this session, so its close is not reported as a failure.
    ///
    /// The two are indistinguishable at the socket: a client that vanished and a session the host
    /// just closed both produce a cancelled connection. Without this, reaping a device that went
    /// quiet reports "Operation canceled" against its name.
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
    ///
    /// The server drops the session from its list here. Without it a finished session stays in the
    /// list, and since ``isAuthorized`` stays `true` on a dead object, that stale entry would go on
    /// authorizing video connections for a client that disconnected long ago.
    var onEnded: (@Sendable () -> Void)?

    /// Whether this session has completed authorization: either the client presented a key
    /// matching its stored pin, or the user confirmed a first-time SAS pairing.
    ///
    /// `state == .ready` is exactly that: every path that reaches `.ready` has passed one of those
    /// two checks, and no other path reaches it.
    var isAuthorized: Bool {
        if case .ready = state { return true }
        return false
    }

    /// Whether this connection asked for the video role and was handed to the video pipeline.
    ///
    /// Set because neither `isAuthorized` nor `state` can say it: a video connection is authorized
    /// by association (the server checks that an authorized control session exists for the same
    /// peer key) and its state is parked at `.failed` on the first frame, which is what stops the
    /// control state machine reading a role frame as a hello. So both questions the server asks
    /// answer "no" for the one connection working exactly as intended.
    ///
    /// The server's silence reaper is the reader: its 30-second limit is for a connection that
    /// never finished a handshake, and one of these is one-directional, so `silence` climbs from
    /// the moment it opens and always crosses. Left in the reaper's path, the picture stops about
    /// half a minute into every session.
    private(set) var isVideoConnection = false

    // MARK: - Messages to the client

    /// The last catalogue this session sent, so an identical one is not sent twice.
    ///
    /// Per session, not per host: suppressing a repeat push has to be relative to what *this*
    /// client has been told, or it becomes "send once per host lifetime" and every client that
    /// connects later is served nothing at all.
    private var lastSentCatalog: CaptureCatalog?

    /// Pushes the capture catalogue, for a client that is in a position to render it.
    ///
    /// Does nothing before authorization, which is a disclosure rule rather than a protocol one:
    /// the catalogue lists every open application and window on this Mac by title, so a peer that
    /// has not finished the handshake must not be handed it. There is no error to report either,
    /// because a session that cannot receive this has already been told why.
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

        let existingPin = pins.pin(for: clientID)
        if let existingPin, !SPKI.matches(existingPin, presentedKey) {
            // Someone is claiming a device ID we already trust, with a key we do not.
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
            // Declared on the same terms, and it covers both directions: this Mac can put a
            // picture on the phone's pasteboard and take one off it.
            supportsClipboardImages: true,
            // Same terms again: a client that has not seen this may not send a mosaic, because the
            // request is a capture source an older Mac cannot decode.
            supportsMosaic: true,
            // Same terms once more. The failure this prevents lands when somebody opens the Apps
            // panel, an ordinary thing to do, and it would end the session rather than show a grid
            // of names.
            supportsSourceThumbnails: true,
            // Same terms once more: a virtual display rotates only for a client that has said it
            // will report its orientation, so an older phone gets the display shape it always had.
            supportsDeviceOrientation: true,
            // Not an unconditional `true` like the flags above: this one names whether the Mac's
            // system software has the private API at all, not just whether this build understands
            // the command, so a Mac that could never make a display does not advertise a row that
            // can only fail.
            supportsVirtualDisplayManagement: VirtualDisplay.isAvailable,
            // This host sends terminal alerts through APNs even while this control channel is
            // connected, so an updated phone need not raise the same banner locally as well.
            pushesTerminalAlertsWhileConnected: true
        ))
        // A trusted client coming back names what it was watching, so capture can start now.
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
    ///
    ///   The control channel's payload cap is not the limit such a frame was held to, and applying
    ///   it here would refuse exactly what chunking exists to allow. A reassembled frame was
    ///   bounded instead by ``ClipboardLimits/maxReassembledBytes`` as it was put together; the
    ///   cap still covers the direct path, a client claiming a 60 MB command in one frame.
    private func handleCommand(_ frame: Frame, assembled: Bool = false) throws {
        switch frame.kind {
        case .command:
            guard assembled || frame.payload.count <= Self.maxControlPayload else {
                throw SessionError.malformedPayload(.command, SessionError.protocolMismatch(client: 0, host: 0))
            }
            let command = try decode(RemoteCommand.self, from: frame, as: .command)
            switch command {
            case .requestClipboard:
                // Always answered: empty text when there is nothing the phone can take, so the
                // phone can say so instead of waiting.
                sendClipboard(onRequestClipboard?() ?? .text(""))
            case .pushClipboard(let text):
                onReceiveClipboard?(.text(text))
            case .pushClipboardImage(let png):
                onReceiveClipboard?(.image(png))
            case .setVideoEnabled(let enabled):
                // Routed here rather than through `onCommand`: the decision is about a connection,
                // and which one comes from this session's key rather than from the command.
                onVideoEnabled?(enabled)
            default:
                onCommand?(command)
            }

        case .videoChunk:
            // The client cutting up something too large for one control message, today a clipboard
            // picture. Put back together and handed to this same function, so nothing below knows
            // the difference between a command that fitted and one that did not.
            try handleChunkedPayload(frame)

        case .ping:
            // The payload is echoed rather than understood: it is the number the client timed this
            // ping with, and returning it is what lets the client match this reply to that
            // question rather than to whichever ping went out most recently. An empty ping gets an
            // empty pong.
            connection.send(Frame(kind: .pong, payload: frame.payload))

        case .terminalRequest:
            guard frame.payload.count <= Self.maxControlPayload else {
                throw SessionError.malformedPayload(.terminalRequest, SessionError.protocolMismatch(client: 0, host: 0))
            }
            let request = try decode(TerminalRequest.self, from: frame, as: .terminalRequest)
            onTerminalRequest?(request) { [weak self] event in
                self?.sendTerminalEvent(event)
            }

        case .videoTransport:
            guard frame.payload.count <= Self.maxControlPayload else {
                throw SessionError.malformedPayload(.videoTransport, SessionError.protocolMismatch(client: 0, host: 0))
            }
            let request = try decode(VideoTransportRequest.self, from: frame, as: .videoTransport)
            onVideoTransportRequest?(request)

        case .videoKeyRequest:
            // A question with no payload: what it asks, whether this session may send video over
            // the relay's datagram path, is answered from the server's own state.
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

    /// Sends the clipboard, cut up if it is too large for one control message.
    ///
    /// A text payload is one frame; a picture is however many it takes, and the client's assembler
    /// puts them back without either end knowing which happened.
    ///
    /// A picture is not sent to a client that has not said it can read one, and nothing is sent in
    /// its place: sending the pasteboard's *text* where a picture was copied is worse than sending
    /// nothing.
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
    ///
    /// A malformed piece costs the payload and not the session, the opposite of the direct path,
    /// and the difference is who is at fault: a command sent whole and decoded wrongly is a bug or
    /// an attack, while a piece that does not fit its neighbours is a failed transfer whose worst
    /// outcome is that the user copies the picture again.
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
