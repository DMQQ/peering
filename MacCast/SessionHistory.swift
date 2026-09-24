import Foundation
import MacCastKit

/// The relay's allowance, counted across every Mac at once.
///
/// **App-wide, and it has to be.** The relay charges every splice a client ID makes to one
/// counter, so the estimate of what is left is a sum over every session that is up and every
/// session that has finished — not a figure belonging to any one Mac. See ``MacSession`` for
/// the per-session half: the record of a single connection in flight.
///
/// ``directPathSummary`` is here for the same reason rather than because it is part of the
/// allowance: it too is a reading over every finished session on this phone, it too belongs to no
/// one Mac, and the same card in the Sessions tab is what draws both.
extension SessionModel {
    /// The client's half of the relay's allowance, and it has to agree with the other half.
    ///
    /// The authority is the relay's own configuration — `Relay/src/config.rs`, which allows one
    /// hour a day on the free plan and no limit on any paid plan. ``RelayPlan`` mirrors that so the
    /// bar can be drawn without asking the server, and this reads the mirror for the plan the user
    /// is actually on rather than for the free one. Reading the wrong plan is how the bar lies: a
    /// free user seeing hours they do not have, or a paid subscriber seeing a meter that should not
    /// exist.
    ///
    /// `nil` is an unlimited plan, which is a plan with no allowance to draw rather than one with a
    /// very large one. The callers ask ``RelayPlan/isUnlimited`` rather than comparing numbers.
    var relayAllowanceSeconds: TimeInterval? {
        storeManager.relayPlan.allowanceSeconds
    }

    /// Every second the relay is charging for in this window, live sessions included.
    ///
    /// **A sum over ``sessions`` and not over a single running one**, which is the correctness
    /// bug the split fixes: the relay splices every open connection to one allowance, so a meter
    /// that added the one session it happened to consider live would under-count by exactly the
    /// Macs it was not looking at — and over-state what is left. The arithmetic itself is
    /// ``RelayAllowance/secondsUsed(records:windowStart:liveRelaySegments:)``, which is where the
    /// test for it lives.
    var relaySecondsUsedThisPeriod: TimeInterval {
        RelayAllowance.secondsUsed(
            records: sessionHistory,
            windowStart: relayPeriodStart,
            liveRelaySegments: relayLiveSegments
        )
    }

    /// The stretch of time each session that is up on the relay has been up for.
    ///
    /// Read off ``sessions`` rather than off the active one, and only the relayed ones: a session
    /// over the LAN is not spending an allowance, and a session that is up but idle still is.
    ///
    /// **A stretch rather than a number of seconds**, because the window is the relay's and not
    /// this phone's: the relay charges a splice as it runs, so a session that was open when the
    /// day turned over is charged for its minutes either side of it out of two allowances, and a
    /// figure with no times in it cannot be placed against either. See
    /// ``MacSession/activeSessionConnectedSegment``.
    private var relayLiveSegments: [DateInterval] {
        sessions
            .filter { $0.connectionPath == .relay }
            .compactMap(\.activeSessionConnectedSegment)
    }

    /// Seconds left in this window's allowance, or `nil` when the plan has no allowance to spend.
    var relaySecondsRemainingEstimate: TimeInterval? {
        RelayAllowance.secondsRemaining(
            allowance: relayAllowanceSeconds,
            records: sessionHistory,
            windowStart: relayPeriodStart,
            liveRelaySegments: relayLiveSegments
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

    /// What the finished sessions on this phone say about the direct path.
    ///
    /// Read off the visible twenty records. The store may retain extra current-day records for the
    /// relay meter, but hidden quota bookkeeping must not quietly enlarge a statistic the list
    /// beneath it cannot show. A session still up has no record yet, so a punch that is working
    /// right now shows up here when it ends rather than while it runs. The arithmetic, the
    /// denominator and what an empty history does are all in
    /// ``DirectPathSummary/init(over:)``, where they can be checked with no device.
    var directPathSummary: DirectPathSummary? {
        DirectPathSummary(over: Array(sessionHistory.prefix(SessionHistoryStore.visibleLimit)))
    }

    /// Count, connected time and video bytes over the same bounded list the Sessions tab shows.
    var recentSessionSummary: SessionHistorySummary {
        SessionHistorySummary(records: sessionHistory)
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
