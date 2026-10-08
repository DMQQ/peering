import CryptoKit
import Foundation
import Network
import RemoteCore
import Security
import os

/// The session's own log, file-private like every other one in the host. See ``AGENTS.md`` on
/// `/usr/bin/log`: zsh's builtin shadows it and the queries silently return nothing.
let hostSessionLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

final class HostSession: @unchecked Sendable {
    /// The largest payload we will accept on the control channel. Commands and catalogs are
    /// small; anything approaching this is a bug or an attack.
    static let maxControlPayload = ProtocolInfo.maxControlPayload

    enum State {
        case awaitingRole
        case awaitingHello
        case awaitingClientCommit
        case awaitingClientReveal
        case awaitingConfirmation
        case awaitingApproval
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

    let connection: PeerConnection
    let identity: SelfSignedIdentity
    let device: DeviceIdentity
    let pins: PinStore
    let emit: @Sendable (HostEvent) -> Void

    /// Whether this connection arrived through the relay rather than from this network.
    let arrivedThroughRelay: Bool

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
    var onPreviewRequest: (@Sendable (PreviewProxyCommand, @escaping @Sendable (PreviewProxyEvent) -> Void) -> Void)?

    var state: State = .awaitingRole
    var clientID = ""
    var clientName = "Unknown device"
    var peerPublicKey: Data?
    /// Whether `.clientConnected` has been emitted, so a disconnect is only ever reported
    /// for a connection the UI was told about in the first place.
    var announced = false

    /// Pieces of one oversized payload from the client, put back as they arrive.
    var clipboardChunks = ClipboardTransfer.reassembler()
    var clipboardFrameID: UInt32 = 0
    var clientSupportsClipboardImages: Bool?
    var clientSupportsTextFocus: Bool?
    var clientSupportsFieldState: Bool?
    var clientSupportsAgentChat: Bool?
    var clientSupportsAgentPermissionModes: Bool?
    var clientSupportsAgentUsage: Bool?

    /// When the last frame arrived from this client, and what stops a session outliving its peer.
    var lastHeard = DispatchTime.now()

    /// Seconds since anything arrived from this client.
    var silence: TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - lastHeard.uptimeNanoseconds) / 1_000_000_000
    }

    var closedByHost = false

    var isAwaitingApproval: Bool { state == .awaitingApproval }

    // Pairing ephemerals. Generated per attempt, never persisted: they exist only to contribute
    // entropy the other side cannot predict.
    var localEphemeral: P256.KeyAgreement.PrivateKey?
    var localNonce: Data?
    var remoteCommitment: Data?
    var remoteEphemeralPublicKey: Data?
    var remoteNonce: Data?
    var pairingTranscript: PairingTranscript?
    var pairingSecret = Data()

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
    var isVideoConnection = false

    // MARK: - Messages to the client

    var lastSentCatalog: CaptureCatalog?

    /// Pushes the capture catalogue, for a client that is in a position to render it.
    func sendCatalog(_ catalog: CaptureCatalog) {
        guard isAuthorized else { return }
        guard catalog != lastSentCatalog else { return }
        lastSentCatalog = catalog
        send(MessageKind.catalog, catalog)
    }





}
