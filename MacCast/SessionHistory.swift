import Foundation
import MacCastKit

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

    var relaySecondsUsedThisPeriod: TimeInterval {
        sessionHistory
            .filter { $0.path == .relay && $0.startedAt >= relayPeriodStart }
            .reduce(0) { $0 + $1.duration }
            + (connectionPath == .relay ? activeSessionDuration : 0)
    }

    /// Seconds left in this window's allowance, or `nil` when the plan has no allowance to spend.
    var relaySecondsRemainingEstimate: TimeInterval? {
        guard let allowance = relayAllowanceSeconds else { return nil }
        return max(0, allowance - relaySecondsUsedThisPeriod)
    }

    /// How much of the window's allowance is left, as a fraction, or `nil` when unlimited.
    var relayAllowanceRemainingFraction: Double? {
        guard let allowance = relayAllowanceSeconds, allowance > 0 else { return nil }
        return (relaySecondsRemainingEstimate ?? 0) / allowance
    }

    var relayVideoBytesThisPeriod: Int64 {
        sessionHistory
            .filter { $0.path == .relay && $0.startedAt >= relayPeriodStart }
            .reduce(0) { $0 + $1.videoBytesReceived }
            + (connectionPath == .relay ? activeSessionBytes : 0)
    }

    /// Which 24-hour window the relay is counting in: epoch seconds divided into days.
    ///
    /// The relay's own arithmetic rather than a calendar's — `Relay/src/quota.rs` divides exactly
    /// this way — so the meter, the bar and the server's own counter all turn over at the same
    /// instant. The number is exposed as well as the date below because the running-low offer
    /// remembers *the window it was last made in*, and a window is easier to remember as the thing
    /// that was counted than as the moment it began.
    var relayWindowNumber: Double {
        (Date().timeIntervalSince1970 / 86_400).rounded(.down)
    }

    /// The start of the window the relay is counting against.
    ///
    /// Deliberately not `startOfDay`, which is the same thing only in UTC. The relay has no
    /// calendar and does not know what time zone the phone is in, so a bar drawn against local
    /// midnight would show a fresh allowance while the relay was still refusing connections.
    private var relayPeriodStart: Date {
        Date(timeIntervalSince1970: relayWindowNumber * 86_400)
    }

    private var activeSessionDuration: TimeInterval {
        guard let activeSessionHistoryStartedAt else { return 0 }
        return Date().timeIntervalSince(activeSessionHistoryStartedAt)
    }

    func beginSessionHistory() {
        guard activeSessionHistoryID == nil else { return }
        activeSessionHistoryID = UUID()
        activeSessionHistoryStartedAt = sessionStartedAt ?? Date()
        activeSessionBytes = 0
        lastBandwidthSampleBytes = renderer.currentSnapshot.bytesEnqueued
        activeSessionLogs = notes
    }

    func captureSessionBandwidth(_ snapshot: VideoRenderer.Snapshot? = nil) {
        guard activeSessionHistoryID != nil else { return }
        let bytes = (snapshot ?? renderer.currentSnapshot).bytesEnqueued
        if bytes >= lastBandwidthSampleBytes {
            activeSessionBytes += bytes - lastBandwidthSampleBytes
        }
        lastBandwidthSampleBytes = bytes
    }

    /// Files the session that has just ended, and asks whether it is worth an offer.
    ///
    /// Returns the record it filed, or `nil` when there was nothing to file — which is the case for
    /// a connection that never reached `.ready`, since ``beginSessionHistory()`` is what creates the
    /// session this reads. Callers are free to ignore the result; the offer is made here rather than
    /// at each of them because both teardown paths want it and neither wants to know about it.
    ///
    /// `@discardableResult` rather than changing the two call sites: this is the one funnel every
    /// ended session passes through, and a hook that has to be remembered at each caller is a hook
    /// that will be missed at the third.
    @discardableResult
    func finishSessionHistory() -> ClientSessionRecord? {
        guard let id = activeSessionHistoryID,
              let startedAt = activeSessionHistoryStartedAt else { return nil }
        captureSessionBandwidth()

        let record = ClientSessionRecord(
            id: id,
            hostID: currentHostID,
            hostName: hostName ?? "A Mac",
            startedAt: startedAt,
            endedAt: Date(),
            path: historyPath(connectionPath),
            videoBytesReceived: activeSessionBytes,
            logs: activeSessionLogs
        )
        sessionHistory.insert(record, at: 0)
        if sessionHistory.count > 30 { sessionHistory.removeLast(sessionHistory.count - 30) }
        SessionHistoryStore.save(sessionHistory)

        activeSessionHistoryID = nil
        activeSessionHistoryStartedAt = nil
        activeSessionBytes = 0
        lastBandwidthSampleBytes = 0
        activeSessionLogs = []

        // Last, and after the five lines above rather than before them.
        //
        // The offer reads ``relaySecondsRemainingEstimate``, which counts the finished session out
        // of the history *and* the live one out of `activeSessionDuration` — so armed before the
        // clear, the session that just ended would be counted twice, and the user would be told
        // they had less relay left than they do. The record is already in `sessionHistory` by this
        // point, which is what makes the figure right rather than merely uncounted.
        offerSubscriptionIfDue(after: record)
        return record
    }

    private func historyPath(_ path: ConnectionPath?) -> ClientSessionRecord.Path {
        switch path {
        case .relay: return .relay
        case .direct: return .direct
        case .lan, nil: return .lan
        }
    }
}

