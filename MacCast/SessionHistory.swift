import Foundation
import MacCastKit

/// The relay's allowance, counted across every Mac at once.
///
/// **App-wide, and it has to be.** The relay charges every splice a client ID makes to one
/// counter, so the estimate of what is left is a sum over every session that is up and every
/// session that has finished — not a figure belonging to any one Mac. See ``MacSession`` for
/// the per-session half: the record of a single connection in flight.
extension SessionModel {
    /// The client's half of the relay's allowance, and it has to agree with the other half.
    ///
    /// The authority is the relay's own configuration — `Relay/src/config.rs`, which allows half an
    /// hour a day on the free plan and three hours on Relay, both in the same rolling 24-hour
    /// window this file counts in. ``RelayPlan`` mirrors those numbers so the bar can be drawn
    /// without asking the server, and this reads the mirror for the plan the user is actually on
    /// rather than for the free one. Reading the wrong plan is how the bar lies: a subscriber
    /// seeing a third of an hour where they bought three, or a free user seeing hours they do not
    /// have.
    ///
    /// `nil` is an unlimited plan, which is a plan with no allowance to draw rather than one with a
    /// very large one. The callers ask ``RelayPlan/isUnlimited`` rather than comparing numbers.
    var relayAllowanceSeconds: TimeInterval? {
        storeManager.relayPlan.allowanceSeconds
    }

    /// Every second the relay is charging for, live sessions included.
    ///
    /// **A sum over ``sessions`` and not over a single running one**, which is the correctness
    /// bug the split fixes: the relay splices every open connection to one allowance, so a meter
    /// that added the one session it happened to consider live would under-count by exactly the
    /// Macs it was not looking at — and over-state what is left. The arithmetic itself is
    /// ``RelayAllowance/secondsUsed(records:windowStart:liveRelaySeconds:)``, which is where the
    /// test for it lives.
    var relaySecondsUsedThisPeriod: TimeInterval {
        RelayAllowance.secondsUsed(
            records: sessionHistory,
            windowStart: relayPeriodStart,
            liveRelaySeconds: relayLiveSeconds
        )
    }

    /// What each session that is up on the relay has spent so far.
    ///
    /// Read off ``sessions`` rather than off the active one, and only the relayed ones: a session
    /// over the LAN is not spending an allowance, and a session that is up but idle still is.
    private var relayLiveSeconds: [TimeInterval] {
        sessions.filter { $0.connectionPath == .relay }.map(\.activeSessionDuration)
    }

    /// Seconds left in this window's allowance, or `nil` when the plan has no allowance to spend.
    var relaySecondsRemainingEstimate: TimeInterval? {
        RelayAllowance.secondsRemaining(
            allowance: relayAllowanceSeconds,
            records: sessionHistory,
            windowStart: relayPeriodStart,
            liveRelaySeconds: relayLiveSeconds
        )
    }

    /// How much of the window's allowance is left, as a fraction, or `nil` when unlimited.
    var relayAllowanceRemainingFraction: Double? {
        guard let allowance = relayAllowanceSeconds, allowance > 0 else { return nil }
        return (relaySecondsRemainingEstimate ?? 0) / allowance
    }

    /// The same sum for the bytes the picture cost, over every relayed session and no other.
    var relayVideoBytesThisPeriod: Int64 {
        sessionHistory
            .filter { $0.path == .relay && $0.startedAt >= relayPeriodStart }
            .reduce(0) { $0 + $1.videoBytesReceived }
            + sessions
                .filter { $0.connectionPath == .relay }
                .reduce(0) { $0 + $1.activeSessionBytes }
    }

    /// Which 24-hour window the relay is counting in: epoch seconds divided into days.
    ///
    /// The relay's own arithmetic rather than a calendar's — `Relay/src/quota.rs` divides exactly
    /// this way — so the meter, the bar and the server's own counter all turn over at the same
    /// instant. The number is exposed as well as the date below because the running-low offer
    /// remembers *the window it was last made in*, and a window is easier to remember as the thing
    /// that was counted than as the moment it began.
    var relayWindowNumber: Double { RelayAllowance.windowNumber(at: Date()) }

    /// The start of the window the relay is counting against.
    ///
    /// Deliberately not `startOfDay`, which is the same thing only in UTC. The relay has no
    /// calendar and does not know what time zone the phone is in, so a bar drawn against local
    /// midnight would show a fresh allowance while the relay was still refusing connections.
    private var relayPeriodStart: Date {
        RelayAllowance.windowStart(windowNumber: relayWindowNumber)
    }
}
