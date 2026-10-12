import CryptoKit
import Crypto
import Foundation
import Network
import Security
import os

extension ClientSession {
    func becomeReady() {
        lock.withLock {
            state = .ready
            _phase = .ready
            // The watchdog's baseline until the first pong arrives. Without it, a session whose
            // first pong is late would be judged against a silence that began before it existed.
            readyAt = Self.monotonicNow()
            noteReadyLocked(at: readyAt ?? 0)
            videoDelivery = VideoDeliveryRecord(readyAt: readyAt)
        }
        emit(.phase(.ready))

        if lock.withLock({ usesRelayedSingleStream }) {
            emit(.video(.connecting))
            lock.withLock { wantsVideoDatagrams = true }
        } else {
            openVideoIfNeeded()
        }
        startPinging()
        startVideoWatch()
        sendPendingClientState()
    }

    func handleReady(_ frame: Frame) {
        switch frame.kind {
        case .catalog:
            guard let catalog = try? MessageCodec.decode(CaptureCatalog.self, from: frame.payload) else {
                clientSessionLog.error("could not decode a capture catalog")
                return
            }
            lock.withLock { _catalog = catalog }
            emit(.catalog(catalog))

        case .pong:
            reportLatency(for: frame)

        case .notice:
            // Decoded leniently on purpose: a notice is advisory, so a payload this build cannot
            // read costs the caption and not the connection.
            let payload = try? MessageCodec.decode(NoticePayload.self, from: frame.payload)
            emit(.remoteNotice(payload))

        case .error:
            let payload = try? MessageCodec.decode(ErrorPayload.self, from: frame.payload)
            if payload?.code == ErrorPayload.hostStoppedCode { emit(.hostStopped) }
            fail(payload?.message ?? "The Mac reported an error.", reason: .hostReportedError)

        case .clipboardContent:
            handleClipboardContent(frame)

        case .textFocus:
            if let focus = try? MessageCodec.decode(TextFocus.self, from: frame.payload) {
                emit(.textFocus(focus))
            }

        case .fieldState:
            if let state = try? MessageCodec.decode(FieldState.self, from: frame.payload) {
                emit(.fieldState(state))
            }

        case .pointerReport:
            if let point = try? MessageCodec.decode(NormalizedPoint.self, from: frame.payload) {
                emit(.pointer(point))
            }

        case .terminalEvent:
            if let event = try? MessageCodec.decode(TerminalEvent.self, from: frame.payload) {
                emit(.terminal(event))
            } else {
                clientSessionLog.error("could not decode a terminal event, so it is being dropped")
            }

        case .previewEvent:
            handlePreviewEvent(frame)

        case .agentEvent:
            if let event = try? MessageCodec.decode(AgentEvent.self, from: frame.payload) {
                emit(.agent(event))
            } else {
                clientSessionLog.error("could not decode an agent event, so it is being dropped")
            }

        // The clipboard's chunks before the picture's: both arrive as the same frame kind, and without this guard the clipboard's pieces would be fed to the picture's assembler.
        case .videoChunk where VideoChunk.innerKind(of: frame) == .clipboardContent:
            handleClipboardChunk(frame)

        case .videoConfig, .videoFrame, .videoChunk, .audioConfig, .audioFrame:
            handleVideoFrame(frame, from: .control)

        case .videoKey:
            handleVideoKey(frame)

        default:
            clientSessionLog.notice("ignoring unexpected \(String(describing: frame.kind), privacy: .public) on a ready session")
        }
    }

    /// Records that the client asked for a picture, or for silence.
    /// A resume needs a socket to travel on: the Mac answers this command on the control channel,
    /// so a resume for a session whose video socket died during the pause reaches the Mac and
    /// changes nothing unless one is opened here.
    func notePictureRequested(_ wanted: Bool) {
        lock.withLock { wantsPicture = wanted }
        if wanted { openVideoIfNeeded() }
    }

    func sendNow(_ command: RemoteCommand) {
        connection()?.send(command)
    }
}

extension ClientSession {
    /// Tells the Mac the app left or returned to the foreground, so it stops encoding for a phone iOS is about to freeze. Only to a Mac that declared it, and only once per change.
    /// Remembered when the session is not ready yet, and sent the moment it is.
    public func sendClientState(background: Bool) {
        lock.withLock { clientNotice.want(background) }
        sendPendingClientState()
    }

    func sendPendingClientState() {
        let pending = lock.withLock { () -> Bool? in
            guard let background = clientNotice.takePending(isReady: state == .ready, hostDeclared: _serverHello?.supportsClientState) else { return nil }
            // The picture was stopped on purpose; the timer for "no picture" starts when it is asked back.
            if !background { lastPictureAt = Self.monotonicNow() }
            return background
        }
        guard let background = pending else { return }
        connection()?.send(.clientState, ClientStatePayload(background: background))
    }
}

extension ClientSession {
    /// Hands the host the Live Activity tokens it needs to push for a suspended phone. Only to a host that declared it and only once the session is ready; returns whether it went out, so the caller can try again when the session comes up.
    @discardableResult
    public func sendActivityToken(_ payload: ActivityTokenPayload) -> Bool {
        let allowed = lock.withLock {
            state == .ready && LiveActivityPushSupport.maySend(toHostDeclared: _serverHello?.supportsLiveActivityPush)
        }
        guard allowed, let connection = connection() else { return false }
        connection.send(.activityToken, payload)
        return true
    }
}

extension ClientSession {
    // MARK: - Ready

    /// Sends a command through ``CommandCoalescer``. The only path input takes, so the 120 Hz to 60 Hz rule and never dropping a `mouseUp` hold in one place.
    public func send(_ command: RemoteCommand) {
        guard isReady else { return }
        // The reconnect has to know which way the picture's switch was asked for, or a paused
        // client would dial a socket that makes the Mac start capturing again. Recorded here
        // rather than at the call site so the two can never be sent apart.
        if case .setVideoEnabled(let enabled) = command { notePictureRequested(enabled) }
        coalescer.enqueue(command)
    }

    public func selectCaptureSource(_ source: CaptureSource) {
        send(.setCaptureSource(source))
    }

    /// Sends a terminal request directly on the authenticated control stream. Unlike pointer
    /// moves, terminal bytes must never be coalesced or reordered.
    public func sendTerminal(_ request: TerminalRequest) {
        guard isReady else { return }
        connection()?.send(.terminalRequest, request)
    }

    /// Sends a request and reports when the network has taken it, or that the session was not ready.
    public func sendTerminal(_ request: TerminalRequest, completion: @escaping @Sendable (Error?) -> Void) {
        guard isReady, let connection = connection() else { return completion(ClientConnection.Failure.cancelled) }
        connection.send(.terminalRequest, request, completion: completion)
    }

    /// Sends one piece of a long transfer once `window` has room for it, and gives the room back when the network has taken it.
    /// - Throws: ``SendWindowFailure`` when an earlier piece failed or the transfer was cancelled.
    public func sendPaced(_ request: TerminalRequest, weight: Int, through window: SendWindow) async throws {
        try await window.reserve(weight)
        sendTerminal(request) { window.complete(weight, error: $0) }
    }

    /// Sends an agent chat request directly on the control stream, bypassing the coalescer: a coalesced prompt or approval would drop turns.
    /// - Returns: `false` when there was no ready connection to hand it to. `true` is not delivery.
    @discardableResult
    public func sendAgent(_ request: AgentRequest) -> Bool {
        guard isReady, let connection = connection() else { return false }
        connection.send(.agentRequest, request)
        return true
    }

    /// Puts a picture on the Mac's pasteboard. Sent on the control channel, not the coalescer: it is not a gesture, and the transport's ordering keeps it ahead of later keystrokes. Larger than one message is split by ``ClipboardTransfer``.
    /// - Returns: `false` for a picture over the limit both ends carry, which nothing is sent for.
    @discardableResult
    public func pushClipboardImage(_ png: Data) -> Bool {
        guard png.count <= ClipboardLimits.maxImageBytes else { return false }
        guard isReady, let connection = connection() else { return false }
        guard let payload = try? MessageCodec.encode(RemoteCommand.pushClipboardImage(png: png)) else {
            return false
        }
        clipboardFrameID &+= 1
        let frames = ClipboardTransfer.frames(kind: .command, payload: payload, frameID: clipboardFrameID)
        guard !frames.isEmpty else { return false }
        for frame in frames { connection.send(frame) }
        return true
    }
}
