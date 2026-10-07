import Foundation
import MacCastKit

/// App-wide: the relay charges every splice a client ID makes to one counter, so what is left is a sum over every session on every Mac.
/// `directPathSummary` is here because it too is a reading over every finished session and belongs to no one Mac.
extension SessionModel {
    /// The authority is `Relay/src/config.rs`; ``RelayPlan`` mirrors it so the bar needs no server. Reading the wrong plan makes the bar lie.
    /// `nil` is an unlimited plan: callers ask `RelayPlan/isUnlimited` rather than comparing numbers.
    var relayAllowanceSeconds: TimeInterval? {
        storeManager.relayPlan.allowanceSeconds
    }

    /// A sum over `sessions`, not one running session: the relay splices every open connection to one allowance, so a single-session meter under-counts.
    var relaySecondsUsedThisPeriod: TimeInterval {
        RelayAllowance.secondsUsed(
            records: sessionHistory,
            windowStart: relayPeriodStart,
            liveRelaySegments: relayLiveSegments
        )
    }

    /// Only relayed sessions: a LAN session spends no allowance, and an idle relayed one still does.
    /// A stretch rather than seconds: a session open at day turnover is charged against two allowances, which needs the times.
    private var relayLiveSegments: [DateInterval] {
        sessions
            .filter { $0.connectionPath == .relay }
            .compactMap(\.activeSessionConnectedSegment)
    }

    var relaySecondsRemainingEstimate: TimeInterval? {
        RelayAllowance.secondsRemaining(
            allowance: relayAllowanceSeconds,
            records: sessionHistory,
            windowStart: relayPeriodStart,
            liveRelaySegments: relayLiveSegments
        )
    }

    var relayAllowanceRemainingFraction: Double? {
        guard let allowance = relayAllowanceSeconds, allowance > 0 else { return nil }
        return (relaySecondsRemainingEstimate ?? 0) / allowance
    }

    var relayVideoBytesThisPeriod: Int64 {
        sessionHistory
            .filter { $0.path == .relay && $0.startedAt >= relayPeriodStart }
            .reduce(0) { $0 + $1.videoBytesReceived }
            + sessions
                .filter { $0.connectionPath == .relay }
                .reduce(0) { $0 + $1.activeSessionBytes }
    }

    /// Read off the visible twenty-five records: hidden quota bookkeeping must not enlarge a statistic the list cannot show. A session still up has no record yet.
    var directPathSummary: DirectPathSummary? {
        DirectPathSummary(over: Array(sessionHistory.prefix(SessionHistoryStore.visibleLimit)))
    }

    var recentSessionSummary: SessionHistorySummary {
        SessionHistorySummary(records: sessionHistory)
    }

    /// The relay's own arithmetic (`Relay/src/quota.rs`), so meter, bar and the server's counter turn over together.
    var relayWindowNumber: Double { RelayAllowance.windowNumber(at: Date()) }

    /// Deliberately not `startOfDay`: the relay has no time zone, so local midnight would show a fresh allowance while the relay still refuses connections.
    private var relayPeriodStart: Date {
        RelayAllowance.windowStart(windowNumber: relayWindowNumber)
    }
}
