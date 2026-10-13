import PeeringKit
import RemoteCore
import SwiftUI

extension MacSession {
    /// Mapped because the raw values differ on purpose: this one is shouted at a diagnostics panel, the card's is set in a chip.
    static func activityPath(_ path: ConnectionPath?) -> SessionActivityAttributes.Path? {
        switch path {
        case .lan: return .lan
        case .relay: return .relay
        case .direct: return .direct
        case nil: return nil
        }
    }

    /// The record is filed first because everything it describes is cleared below, and the player is released because its `deinit` stops the engine.
    func endSession(deliberate: Bool) {
        userEndedDeliberately = deliberate
        finishSessionHistory()
        connectTask?.cancel()
        connectTask = nil
        // Cleared here rather than in `stopReconnecting()`, which every rung calls before dialling: this is the end of the episode, and that is not.
        reconnectingSince = nil
        stopReconnecting()
        dialRace?.cancel()
        wire?.disconnect()
        wire = nil
        videoPoll?.cancel()
        videoPoll = nil
        audioPlayer = nil
        connectionPath = nil
        sessionStartedAt = nil
        picturePaused = false
        phase = .disconnected
    }

    /// Everything goes through the session's coalescer, so the rules about what may be merged and what must never be dropped live in one place.
    func send(_ command: RemoteCommand) {
        wire?.send(command)
    }

    func append(note: String) {
        notes.append(note)
        if notes.count > 12 { notes.removeFirst(notes.count - 12) }
        if activeSessionHistoryID != nil {
            activeSessionLogs.append(Self.stamp(note))
            if activeSessionLogs.count > Self.sessionLogLimit {
                activeSessionLogs.removeFirst(activeSessionLogs.count - Self.sessionLogLimit)
            }
        }
    }
}
