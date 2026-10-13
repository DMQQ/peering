import CryptoKit
import Foundation
import PeeringKit
import Network
import RemoteCore
import Security
import os

extension HostSession {
    /// - Parameter assembled: whether this frame was put back together from chunks on this end.
    func handleCommand(_ frame: Frame, assembled: Bool = false) throws {
        switch frame.kind {
        case .command:
            guard assembled || frame.payload.count <= Self.maxControlPayload else {
                throw SessionError.malformedPayload(.command, SessionError.protocolMismatch(client: 0, host: 0))
            }
            // A paste sent straight after a clipboard push must find what was pushed, and the pasteboard is written on the main thread without this queue waiting for it.
            if clipboardWritesInFlight > 0, commandsHeldForClipboard.count < Self.maxCommandsHeldForClipboard {
                commandsHeldForClipboard.append((frame, assembled))
                return
            }
            let command = try decode(RemoteCommand.self, from: frame, as: .command)
            switch command {
            case .requestClipboard:
                requestClipboard()
            case .pushClipboard(let text):
                receiveClipboard(.text(text))
            case .pushClipboardImage(let png):
                receiveClipboard(.image(png))
            case .setVideoEnabled(let enabled):
                perform(pictureState.pictureRequested(enabled))
            default:
                heldInput.observe(command)
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

        case .previewRequest:
            guard frame.payload.count <= PreviewProxyLimits.maxRequestFrameBytes else {
                throw SessionError.malformedPayload(.previewRequest, SessionError.protocolMismatch(client: 0, host: 0))
            }
            let command = try decode(PreviewProxyCommand.self, from: frame, as: .previewRequest)
            onPreviewRequest?(command) { [weak self] event in
                self?.sendPreviewEvent(event)
            }

        case .videoTransport:
            guard frame.payload.count <= Self.maxControlPayload else {
                throw SessionError.malformedPayload(.videoTransport, SessionError.protocolMismatch(client: 0, host: 0))
            }
            let request = try decode(VideoTransportRequest.self, from: frame, as: .videoTransport)
            onVideoTransportRequest?(request)

        case .clientState:
            guard frame.payload.count <= Self.maxControlPayload else {
                throw SessionError.malformedPayload(.clientState, SessionError.protocolMismatch(client: 0, host: 0))
            }
            let state = try decode(ClientStatePayload.self, from: frame, as: .clientState)
            hostSessionLog.notice("client \(state.background ? "left" : "returned to", privacy: .public) the foreground")
            perform(pictureState.clientBackground(state.background))
            onClientBackground?(state.background)
            deliverWhatWasHeld(for: state.background)

        case .activityToken:
            guard frame.payload.count <= Self.maxControlPayload else {
                throw SessionError.malformedPayload(.activityToken, SessionError.protocolMismatch(client: 0, host: 0))
            }
            let tokens = try decode(ActivityTokenPayload.self, from: frame, as: .activityToken)
            let plausible = [tokens.pushToken, tokens.pushToStartToken].compactMap { $0 }.allSatisfy(LiveActivityPushSupport.isPlausible)
            guard plausible else {
                hostSessionLog.notice("ignored a Live Activity token that is not hex")
                return
            }
            onActivityToken?(tokens)

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

    private func requestClipboard() {
        guard let onRequestClipboard else {
            sendClipboard(.text(""))
            return
        }
        onRequestClipboard { [weak self] payload in
            guard let self else { return }
            connection.onQueue { [weak self] in self?.sendClipboard(payload ?? .text("")) }
        }
    }

    private func receiveClipboard(_ payload: ClipboardPayload) {
        guard let onReceiveClipboard else { return }
        clipboardWritesInFlight += 1
        onReceiveClipboard(payload) { [weak self] in
            guard let self else { return }
            connection.onQueue { [weak self] in self?.clipboardWriteFinished() }
        }
    }

    private func clipboardWriteFinished() {
        clipboardWritesInFlight -= 1
        guard clipboardWritesInFlight == 0, state != .failed else { return }
        let held = commandsHeldForClipboard
        commandsHeldForClipboard = []
        for (frame, assembled) in held {
            do {
                try handleCommand(frame, assembled: assembled)
            } catch {
                fail(error)
                return
            }
        }
    }

    /// Resuming attaches the video connection again, which asks the encoder for a keyframe.
    private func perform(_ action: ClientPictureState.Action) {
        switch action {
        case .none: break
        case .pauseVideo: onVideoEnabled?(false)
        case .resumeVideo: onVideoEnabled?(true)
        }
    }

    func sendTerminalEvent(_ event: TerminalEvent) {
        guard isAuthorized else { return }
        if case .output = event, !outputGate.admitsTerminalOutput() { return }
        send(.terminalEvent, event)
    }

    /// On return, the agent events kept meanwhile go out in order, and the shells are replayed from the Mac's history if their output was not sent.
    func deliverWhatWasHeld(for background: Bool) {
        guard let returned = outputGate.clientBackground(background) else { return }
        for event in returned.heldAgentEvents { send(.agentEvent, event) }
        if returned.terminalNeedsReplay {
            onTerminalRequest?(.list) { [weak self] event in self?.sendTerminalEvent(event) }
        }
    }

    /// The restraint is on this side: a chat's events travel to the client that started it, and a
    /// client that has not said it can read an `agentEvent` frame must never be sent one, because
    /// an unknown frame kind ends its session rather than being dropped.
    func sendAgentEvent(_ event: AgentEvent) {
        guard isAuthorized, AgentChatSupport.mayReceive(clientDeclared: clientSupportsAgentChat) else { return }
        // A frame kind an older phone cannot decode ends its session, so it is withheld from one.
        if case .permissionModeChanged = event, clientSupportsAgentPermissionModes != true { return }
        if case .usageChanged = event, clientSupportsAgentUsage != true { return }
        if outputGate.holdsAgentEvent(event, cost: (try? MessageCodec.encode(event))?.count ?? 1024) { return }
        send(.agentEvent, event)
    }

    func sendPreviewEvent(_ event: PreviewProxyEvent) {
        guard isAuthorized else { return }
        send(.previewEvent, event)
    }

    func sendClipboard(_ payload: ClipboardPayload) {
        guard isAuthorized else { return }
        if payload.kind == .image, !ClipboardImages.mayReceive(clientDeclared: clientSupportsClipboardImages) {
            hostSessionLog.notice("not sending a clipboard picture to a client that cannot read one")
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
    func handleChunkedPayload(_ frame: Frame) throws {
        guard let whole = try? clipboardChunks.ingest(frame) else { return }
        try handleCommand(whole, assembled: true)
    }
}
