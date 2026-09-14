import CryptoKit
import Foundation
import Network
import RemoteCore
import Security

/// Drives one connection from its first frame to a usable session.
///
/// All state is mutated on the server's serial queue, which is also the connection's
/// queue, so no locking is needed here. That is a deliberate simplification: a session is
/// a state machine, and state machines are much easier to keep correct when they cannot
/// be touched from two threads at once.
final class HostSession: @unchecked Sendable {
    /// The largest payload we will accept on the control channel. Commands and catalogs are
    /// small; anything approaching this is a bug or an attack.
    private static let maxControlPayload = 64 * 1024

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

    /// Invoked once the session is authenticated and may carry commands.
    var onCommand: (@Sendable (RemoteCommand) -> Void)?
    /// Invoked with the video connection once a client opens one.
    var onVideoConnection: (@Sendable (PeerConnection) -> Void)?

    private var state: State = .awaitingRole
    private(set) var clientID = ""
    private var clientName = "Unknown device"
    /// Readable so the server can match a video connection to the control session that
    /// authorizes it. Both are on the same serial queue, so no lock is needed.
    private(set) var peerPublicKey: Data?
    /// Whether `.clientConnected` has been emitted, so a disconnect is only ever reported
    /// for a connection the UI was told about in the first place.
    private var announced = false

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
        emit: @escaping @Sendable (HostEvent) -> Void
    ) {
        self.connection = connection
        self.identity = identity
        self.device = device
        self.pins = pins
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
            if let error, state != .failed {
                emit(.failed("Connection ended: \(error.localizedDescription)"))
            }

            // Only for a connection that was actually announced. Otherwise a client that
            // fails during TLS or before its hello produces "Unknown device disconnected",
            // naming a device the user never saw arrive.
            if announced {
                emit(.clientDisconnected(clientName: clientName))
            }

            onEnded?()
        }
        connection.start()
    }

    func cancel() {
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
        let hello = try decode(ClientHello.self, from: frame, as: .clientHello)

        guard hello.protocolVersion == ProtocolInfo.version else {
            throw SessionError.protocolMismatch(client: hello.protocolVersion, host: ProtocolInfo.version)
        }

        // The peer's key comes from the TLS certificate, never from the message. A client
        // that could simply declare its own public key would make pinning pointless.
        guard let presentedKey = connection.peerPublicKey else { throw SessionError.noPeerCertificate }

        clientID = hello.clientID
        clientName = hello.clientName
        peerPublicKey = presentedKey

        announced = true
        emit(.clientConnected(
            clientName: clientName,
            detail: "\(connection.negotiatedTLSVersion) · \(presentedKey.count)-byte key"
        ))

        let existingPin = pins.pin(for: clientID)
        if let existingPin, !SPKI.matches(existingPin, presentedKey) {
            // Someone is claiming a device ID we already trust, with a key we do not.
            throw SessionError.clientKeyMismatch(clientID: clientID)
        }

        let alreadyPaired = existingPin != nil
        send(.serverHello, ServerHello(
            serverID: device.id,
            hostName: device.name,
            protocolVersion: ProtocolInfo.version,
            alreadyPaired: alreadyPaired
        ))

        if alreadyPaired {
            state = .ready
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

        emit(.pairingCode(code: PairingSAS.code(for: transcript), clientName: clientName))
        state = .awaitingConfirmation
    }

    private func handlePairConfirm(_ frame: Frame) throws {
        guard frame.kind == .pairConfirm else { throw SessionError.unexpectedMessage(frame.kind) }
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
    }

    // MARK: - Authenticated commands

    private func handleCommand(_ frame: Frame) throws {
        switch frame.kind {
        case .command:
            guard frame.payload.count <= Self.maxControlPayload else {
                throw SessionError.malformedPayload(.command, SessionError.protocolMismatch(client: 0, host: 0))
            }
            let command = try decode(RemoteCommand.self, from: frame, as: .command)
            onCommand?(command)

        case .ping:
            connection.send(Frame(kind: .pong))

        default:
            throw SessionError.unexpectedMessage(frame.kind)
        }
    }

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, from frame: Frame, as kind: MessageKind) throws -> T {
        do {
            return try MessageCodec.decode(type, from: frame.payload)
        } catch {
            throw SessionError.malformedPayload(kind, error)
        }
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
