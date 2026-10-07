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
            fail(payload?.message ?? "The Mac reported an error.")

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

        case .terminalEvent:
            if let event = try? MessageCodec.decode(TerminalEvent.self, from: frame.payload) {
                emit(.terminal(event))
            } else {
                clientSessionLog.error("could not decode a terminal event, so it is being dropped")
            }

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
