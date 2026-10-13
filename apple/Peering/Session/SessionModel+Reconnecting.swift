import MacCastKit
import RemoteCore
import SwiftUI

extension SessionModel {
    /// Read off the session on screen, because the card describes one Mac.
    var isReconnecting: Bool {
        get { activeSession?.isReconnecting ?? false }
        set { activeSession?.isReconnecting = newValue }
    }

    /// The rule is ``SessionResume``'s; screens ask here to read one answer.
    var isResumingAfterDrop: Bool { activeSession?.isResumingAfterDrop ?? false }

    var isBeingPutBack: Bool { activeSession?.isBeingPutBack ?? false }

    /// Spread out: the usual cause is a sleeping Mac or a brief network loss, and retrying every second spends radio and battery on an unchanged answer. Five attempts over about forty seconds cover a Wi-Fi roam and a Mac waking.
    static let reconnectDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(20),
    ]

    /// A resume is silent, so "still coming back" and "gone" look alike and the only difference the user can act on is how long they wonder: hence short, with a nearly immediate first rung.
    /// The two ladders share a counter: `reconnectAttempt` indexes into whichever is in use and is carried across a dial, so the shorter simply runs out sooner.
    /// Long enough to outlast the Mac app restarting (quit, relaunch, listening again), which takes more than the first three rungs: they ended the resume in about four seconds, before a restarted Mac was up.
    static let resumeReconnectDelays: [Duration] = [
        .milliseconds(250), .seconds(1), .seconds(3), .seconds(5), .seconds(8), .seconds(10),
    ]

    /// A rung is a wait plus a dial that can take ten seconds to fail, so "three rungs" is not a duration, and a dial that never answers is not bounded by the count. This bound does not depend on the network answering and covers the restoration, which dials once with no ladder.
    static let reconnectWindow: TimeInterval = 30

    var reconnectTask: Task<Void, Never>? {
        get { activeSession?.reconnectTask }
        set { activeSession?.reconnectTask = newValue }
    }

    var reconnectAttempt: Int {
        get { activeSession?.reconnectAttempt ?? 0 }
        set { activeSession?.reconnectAttempt = newValue }
    }

    /// One flag for every Mac, so the last to finish clears it, asked of the sessions.
    func clearResumingIfNothingIsUnderWay() {
        guard !sessions.contains(where: { $0.isResumingAfterDrop }) else { return }
        isResuming = false
    }
}
