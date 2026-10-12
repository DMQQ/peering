import Foundation
import MacCastKit
import os

/// What the host remembers about each open session for the end event: who joined it, how, and what it had already cost when it began. Keyed by client ID, never sent.
final class HostSessionFacts: Sendable {
    static let shared = HostSessionFacts()

    struct Entry {
        var sessionRef: String?
        var clientPlatform: String?
        var viaRelay: Bool
        var endReason: HostEventCodes.EndReason?
        var droppedAtStart = 0
        var restartsAtStart = 0
        var started = Date()
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var encoderRestarts = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The tag of the session in progress, for an event that has no owner of its own. With two phones at once it is nil, because either could be blamed for the other's failure.
    var soleSessionRef: String? {
        state.withLock { $0.entries.count == 1 ? $0.entries.values.first?.sessionRef : nil }
    }

    /// Returns the entry this one replaces, which is ended as `replaced` by the caller.
    func opened(clientID: String, sessionRef: String?, clientPlatform: String?, viaRelay: Bool) -> Entry? {
        state.withLock { state in
            let previous = state.entries[clientID]
            state.entries[clientID] = Entry(
                sessionRef: SessionRef.sanitized(sessionRef), clientPlatform: clientPlatform, viaRelay: viaRelay,
                restartsAtStart: state.encoderRestarts
            )
            return previous
        }
    }

    func baseline(clientID: String, droppedFrames: Int) {
        state.withLock { $0.entries[clientID]?.droppedAtStart = droppedFrames }
    }

    func peek(clientID: String) -> Entry? {
        state.withLock { $0.entries[clientID] }
    }

    /// The first reason wins: a silent session that is then cancelled by the reaper is silence, not a client close.
    func noteEnd(clientID: String, _ reason: HostEventCodes.EndReason) {
        state.withLock { state in
            if state.entries[clientID]?.endReason == nil { state.entries[clientID]?.endReason = reason }
        }
    }

    func noteEndForAll(_ reason: HostEventCodes.EndReason) {
        state.withLock { state in
            for key in state.entries.keys where state.entries[key]?.endReason == nil { state.entries[key]?.endReason = reason }
        }
    }

    func noteEncoderRestart() {
        state.withLock { $0.encoderRestarts += 1 }
    }

    func closed(clientID: String) -> (entry: Entry, encoderRestarts: Int)? {
        state.withLock { state in
            guard let entry = state.entries.removeValue(forKey: clientID) else { return nil }
            return (entry, max(0, state.encoderRestarts - entry.restartsAtStart))
        }
    }
}
