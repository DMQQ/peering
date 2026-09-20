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
/// All state is mutated on the server's serial queue, which is also the connection's
/// queue, so no locking is needed here. That is a deliberate simplification: a session is
/// a state machine, and state machines are much easier to keep correct when they cannot
/// be touched from two threads at once.
final class HostSession: @unchecked Sendable {
    /// The largest payload we will accept on the control channel. Commands and catalogs are
    /// small; anything approaching this is a bug or an attack.
    ///
    /// Shared rather than repeated, because it is the number the video fallback cuts its
    /// chunks to fit under — see ``ProtocolInfo/maxControlPayload``.
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
    /// The session's own behaviour does not depend on it — TLS and the handshake are the same
    /// either way, which is the whole point of the design — but the *user's* does. A pairing
    /// prompt on a relayed connection is asking someone at this Mac to compare digits with a
    /// person who is not in the room, and the card cannot say that unless it is told.
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
    /// Routed from the session rather than decided here because a session knows only its own
    /// connection, while the answer needs the video pipeline and the peer that is being served.
    /// Given to the server, which has both.
    var onVideoTransportRequest: (@Sendable (VideoTransportRequest) -> Void)?
    /// Called when an authorized client asks for the secret that seals video datagrams.
    ///
    /// Answers with the secret, or `nil` for a refusal — and the refusal is silence rather
    /// than an error, because there is nothing for the client to do about it: a Mac that does
    /// not answer is a Mac still sending the picture down the stream this session already
    /// has. The server holds the relay's allocation and the pipeline, which are the two
    /// things this needs and the two things a session does not have.
    var onVideoKeyRequest: (@Sendable () -> Data?)?

    /// Called when a client asks for the picture to be turned on or off. See
    /// ``RemoteCommand/setVideoEnabled(_:)``.
    ///
    /// Carries the request and nothing else. The connection to act on is found from the key
    /// this session presented, which the server adds on its way out: the same division as
    /// ``onVideoTransportRequest``, and for the same reason: a session knows one connection,
    /// while the answer needs whichever connection is currently being served.
    var onVideoEnabled: (@Sendable (Bool) -> Void)?

    /// Called when the client requests the clipboard. Return `nil` to send nothing.
    ///
    /// A payload rather than a string, because the pasteboard may be holding a picture and only
    /// this end can find that out. See ``ClipboardPayload``.
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
    /// **The only assembler this end has**, unlike the client's two: a picture's chunks travel host
    /// to client and never the other way, so the only thing a client ever cuts up for the host is a
    /// command with a screenshot in it. See ``ClipboardTransfer/reassembler()``.
    private var clipboardChunks = ClipboardTransfer.reassembler()
    /// Which clipboard payload is being cut up on the way out, so the client can tell two apart.
    private var clipboardFrameID: UInt32 = 0
    /// What the client said about reading a picture, off its hello. `nil` is a client built before
    /// the field existed, which is a no. See ``ClipboardImages/mayReceive(clientDeclared:)``.
    private var clientSupportsClipboardImages: Bool?

    /// When the last frame arrived from this client, and what stops a session outliving its peer.
    ///
    /// The client pings once a second — see `ClientSession.startPinging` — so silence here is
    /// evidence rather than an inference. It exists because TCP does not reliably report that a
    /// peer is gone: a phone whose app is killed while the network has already moved on sends no
    /// FIN, and the host then holds a session that is still authorized, still suppresses the
    /// Bonjour advertisement, and is still shown as connected, indefinitely. That is not
    /// hypothetical — it is what a Mac left invisible on its own network for eighteen minutes
    /// with a session the phone had long forgotten looked like.
    ///
    /// Written in ``handle(_:)`` and read by the server's reaper, both on the server's serial
    /// queue — the same reason ``state`` needs no lock.
    private var lastHeard = DispatchTime.now()

    /// Seconds since anything arrived from this client.
    var silence: TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - lastHeard.uptimeNanoseconds) / 1_000_000_000
    }

    /// Set when *we* end this session, so its close is not reported as a failure.
    ///
    /// The two are indistinguishable at the socket: a client that vanished and a session the
    /// host just closed both produce a cancelled connection. Without this, reaping a device that
    /// simply went quiet reports "Connection ended: Operation canceled" against its name — an
    /// error message about nothing, shown under a device the user only wanted to stop seeing.
    private var closedByHost = false

    // Pairing ephemerals. Generated per attempt, never persisted — they exist only to
    // contribute entropy the other side cannot predict.
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

            // Runs on the same serial queue as `handle`, so `state` is safe to read here.
            // A close that follows our own `fail` carries no new information — the real
            // explanation was already emitted, and the cancellation error it produces
            // ("Operation canceled") would read in the UI as a second, unrelated problem.
            if let error, state != .failed, !closedByHost {
                emit(.failed("Connection ended: \(error.localizedDescription)"))
            }

            // Only for a connection that was actually announced. Otherwise a client that
            // fails during TLS or before its hello produces "Unknown device disconnected",
            // naming a device the user never saw arrive.
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

    /// Called once, on the server queue, when this session's connection is gone.
    ///
    /// The server needs this to drop the session from its list. Without it a finished
    /// session stays in the list — and since ``isAuthorized`` stays `true` on a dead
    /// object, that stale entry would go on authorizing video connections for a client
    /// that disconnected long ago.
    var onEnded: (@Sendable () -> Void)?

    /// Whether this session has completed authorization: either the client presented a key
    /// matching its stored pin, or the user confirmed a first-time SAS pairing.
    ///
    /// `state == .ready` is exactly that condition — every path that reaches `.ready` has
    /// passed one of those two checks, and no other path reaches it.
    var isAuthorized: Bool {
        if case .ready = state { return true }
        return false
    }

    // MARK: - Messages to the client

    /// The last catalogue this session sent, so an identical one is not sent twice.
    ///
    /// **Per session, not per host, and that is the whole point of it living here.** An
    /// unchanged list should not rebuild a picker the user may be looking at, so repeat
    /// pushes are suppressed — but the suppression has to be relative to *what this client
    /// has already been told*. Kept host-wide it degrades into "send once per host lifetime",
    /// and every client that connects afterwards is served nothing at all: the picker comes
    /// up empty and neither side has an error to show for it.
    private var lastSentCatalog: CaptureCatalog?

    /// Pushes the capture catalogue, for a client that is in a position to render it.
    ///
    /// Does nothing before the session is authorized, and that is a disclosure rule rather
    /// than a protocol one: the catalogue lists every open application and window on this
    /// Mac by title, so a peer that has not finished the handshake — or that failed it —
    /// must not be handed it. There is no error to report either, because a session that
    /// cannot receive this has already been told why it is not being served.
    func sendCatalog(_ catalog: CaptureCatalog) {
        guard isAuthorized else { return }
        guard catalog != lastSentCatalog else { return }
        lastSentCatalog = catalog
        send(MessageKind.catalog, catalog)
    }

    // MARK: - Message handling

    private func handle(_ frame: Frame) {
        // Stamped before anything is done with it, and for every frame rather than only pings:
        // a client that is sending video requests but has stopped answering pings is no more
        // present than one that has stopped entirely, and liveness is "anything at all arrived".
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
            // A video connection is opened *after* the control connection is authenticated,
            // but it is a separate socket and carries no handshake of its own. It is
            // accepted here and handed to the video pipeline, which verifies that an
            // authenticated control session exists for the same peer key.
            state = .failed
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

        // The peer's key comes from the TLS certificate, never from the message. A client
        // that could simply declare its own public key would make pinning pointless.
        guard let presentedKey = connection.peerPublicKey else { throw SessionError.noPeerCertificate }

        clientID = hello.clientID
        clientName = hello.clientName
        peerPublicKey = presentedKey
        // Read here and not assumed, so that a client too old to read a picture is never sent one.
        // The two ends speak the same protocol version either way, so this flag is the only thing
        // that tells them apart. See ``ClipboardImages/mayReceive(clientDeclared:)``.
        clientSupportsClipboardImages = hello.supportsClipboardImages

        let existingPin = pins.pin(for: clientID)
        if let existingPin, !SPKI.matches(existingPin, presentedKey) {
            // Someone is claiming a device ID we already trust, with a key we do not.
            throw SessionError.clientKeyMismatch(clientID: clientID)
        }

        // Announced only after the key check: a client that fails it must not appear in the
        // session list, because the disconnect that follows would name a device the UI
        // never showed arriving.
        announced = true
        emit(.clientConnected(
            clientID: clientID,
            clientName: clientName,
            detail: "\(connection.negotiatedTLSVersion) · \(presentedKey.count)-byte key"
        ))

        let alreadyPaired = existingPin != nil
        send(.serverHello, ServerHello(
            serverID: device.id,
            hostName: device.name,
            protocolVersion: ProtocolInfo.version,
            alreadyPaired: alreadyPaired,
            // Hardware addresses are useful only to trusted clients for Wake-on-LAN. The
            // server hello precedes first-pairing confirmation, so exposing them there would
            // let any device on the LAN collect them without being accepted.
            macAddresses: alreadyPaired ? NetworkInterfaceInfo.hardwareMACAddresses() : nil,
            // Declared to everyone, trusted or not: it is the version of this Mac's software
            // rather than anything about the user, and a client that sends the pause command to
            // a Mac that has not said this gets a decode failure in the middle of a session
            // instead of the honest degradation the flag exists for.
            supportsVideoPause: true,
            // Declared on the same terms and for the same reason, and it covers both directions:
            // this Mac can put a picture on the phone's pasteboard and can take one off it, so a
            // client that sees this may send the command and may expect the answer.
            supportsClipboardImages: true
        ))

        if alreadyPaired {
            state = .ready
            onAuthorized?(connection)
            return
        }
        try beginPairing()
    }

    // MARK: - Pairing

    /// Starts the commitment exchange. See ``PairingSAS`` for why the commitment exists:
    /// without it, an active attacker can grind a keypair until its own contribution
    /// reproduces the digits this host is about to put on screen.
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
            // Reporting success here would tell the user they are paired while the next
            // connection silently fails, so the write result is checked rather than assumed.
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
    ///   **The control channel's payload cap is not the limit such a frame was held to, and
    ///   applying it here would refuse exactly what chunking exists to allow.** A picture on the
    ///   clipboard is megabytes of JSON, so it is cut up by the client and put back by
    ///   ``handleChunkedPayload(_:)`` before it arrives here. The cap above still protects the
    ///   direct path, which is where it was always doing its work: a client claiming a 60 MB
    ///   command in one frame. A reassembled one was bounded instead by
    ///   ``ClipboardLimits/maxReassembledBytes``, as it was put together.
    private func handleCommand(_ frame: Frame, assembled: Bool = false) throws {
        switch frame.kind {
        case .command:
            guard assembled || frame.payload.count <= Self.maxControlPayload else {
                throw SessionError.malformedPayload(.command, SessionError.protocolMismatch(client: 0, host: 0))
            }
            let command = try decode(RemoteCommand.self, from: frame, as: .command)
            switch command {
            case .requestClipboard:
                // Only if there is something to send. An empty pasteboard gets silence, which is
                // what it has always got: the client's pull is left outstanding and the next one
                // replaces it.
                if let payload = onRequestClipboard?() {
                    sendClipboard(payload)
                }
            case .pushClipboard(let text):
                onReceiveClipboard?(.text(text))
            case .pushClipboardImage(let png):
                onReceiveClipboard?(.image(png))
            case .setVideoEnabled(let enabled):
                // Routed here rather than through `onCommand`, because the decision is about a
                // *connection* and which one it is comes from this session's key rather than
                // from the command. See ``onVideoEnabled``.
                onVideoEnabled?(enabled)
            default:
                onCommand?(command)
            }

        case .videoChunk:
            // The client cutting up something too large for one control message, which today means
            // a picture on the clipboard and nothing else. Put back together and handed to this
            // same function, so nothing below here knows the difference between a command that
            // fitted and one that did not. See ``ClipboardTransfer``.
            try handleChunkedPayload(frame)

        case .ping:
            // The payload is handed back rather than understood: it is the number the client timed
            // this ping with, and echoing it is what lets the client match this reply to that
            // question instead of to whichever ping went out most recently. An empty ping gets an
            // empty pong, so a client older than this handler is unaffected.
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
            // A question with no payload. What it asks — may this session send video over the
            // relay's datagram path — is answered from the server's own state, so there is
            // nothing here to read and nothing to refuse for being malformed.
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
    /// A text payload is one frame and always was; a picture is however many it takes. The client's
    /// assembler puts them back without either end having to know which of the two happened, which
    /// is the point of doing the cutting below the payload rather than above it.
    ///
    /// **A picture is not sent to a client that has not said it can read one.** Nothing is sent in
    /// its place: the alternative is to send the pasteboard's *text* where a picture is what the
    /// user copied, and the wrong thing pasted is worse than nothing pasted. A client that has not
    /// said so is a client whose clipboard carries text, which is what it did before any of this.
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
    /// **A malformed piece costs the payload and not the session**, which is the opposite of what
    /// the direct path does with a malformed command, and the difference is who is at fault. A
    /// command sent whole and decoded wrongly is a bug or an attack and the session should not
    /// continue; a piece that does not fit its neighbours is a transfer that failed, and the worst
    /// thing that can happen if it is ignored is that the user copies the picture again.
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
    /// Advisory, so it never fails the session: the control channel is healthy and so is the
    /// video channel. This is a caption for the frames, not a complaint about them.
    func sendNotice(_ payload: NoticePayload) {
        send(MessageKind.notice, payload)
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

        // Cancel only once the explanation has actually been handed to the transport.
        // Cancelling immediately after `send` discards the queued frame, and the peer sees
        // a bare disconnect with no reason — which is exactly the case where a user most
        // needs to know why their device was turned away.
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
