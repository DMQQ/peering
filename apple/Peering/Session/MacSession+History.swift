import Foundation
import MacCastKit

extension MacSession {
    /// **This segment of it, not the record it belongs to.** A record continued across a drop
    /// covers a span with the gap in it, and the half of the session that has already happened is
    /// still in the history, as the very record this one continues: counting it here as well would
    /// charge the relay for the same minutes twice. See ``SessionContinuation``.
    var activeSessionDuration: TimeInterval {
        guard let activeSessionHistoryStartedAt else { return 0 }
        return Date().timeIntervalSince(activeSessionHistoryStartedAt)
    }

    /// **A stretch rather than a number of seconds, because the window is the relay's and not this
    /// phone's.** The relay charges a splice as it runs, against a bucket that turns over at the
    /// epoch day, so a session that was open when the day turned over is charged for its minutes
    /// either side of it out of two allowances, and a figure with no times in it cannot be placed
    /// against either. See ``RelayAllowance/secondsUsed(records:windowStart:liveRelaySegments:)``.
    var activeSessionConnectedSegment: DateInterval? {
        guard let activeSessionHistoryStartedAt else { return nil }
        return DateInterval(start: activeSessionHistoryStartedAt, duration: activeSessionDuration)
    }

    func beginSessionHistory(resuming: Bool) {
        guard activeSessionHistoryID == nil else { return }
        activeSessionHistoryID = UUID()
        activeSessionHistoryStartedAt = sessionStartedAt ?? Date()
        activeSessionBytes = 0
        lastBandwidthSampleBytes = renderer.currentSnapshot.bytesEnqueued
        activeSessionLogs = notes
        activeSessionContinuation = resuming
            ? SessionContinuation.continued(
                in: model.sessionHistory,
                hostID: hostID,
                // The path this attempt came back on, which a continuation is refused across:
                // the relay meters a record by its path and its connected time together, and a
                // record carrying minutes from two paths under one of them is either charging
                // for a splice that did not happen or losing one that did.
                path: ConnectionPath.recordPath(of: connectionPath)
            )
            : nil
    }

    func captureSessionBandwidth(_ snapshot: VideoRenderer.Snapshot? = nil) {
        guard activeSessionHistoryID != nil else { return }
        let bytes = (snapshot ?? renderer.currentSnapshot).bytesEnqueued
        if bytes >= lastBandwidthSampleBytes {
            activeSessionBytes += bytes - lastBandwidthSampleBytes
        }
        lastBandwidthSampleBytes = bytes
    }

    /// **A session that was put back after a drop is filed as the record it continued**, which is
    /// the row the user already had rather than a second one beside it: the same identity, the same
    /// start, its bytes and its log carried forward, and the gap it was not connected for in the
    /// span but not in the meter. See ``SessionContinuation``.
    @discardableResult
    func finishSessionHistory() -> ClientSessionRecord? {
        guard let id = activeSessionHistoryID,
              let startedAt = activeSessionHistoryStartedAt else { return nil }
        captureSessionBandwidth()

        let endedAt = Date()
        let continuation = activeSessionContinuation
            ?? SessionContinuation(id: id, startedAt: startedAt)
        let record = continuation.filed(
            endedAt: endedAt,
            // **The start of this segment, which is not the record's start.** The record's own
            // start is the continuation's, and the distance between the two is the gap: it is what
            // the row's duration is for the user to read, and what the connected seconds stay out
            // of. See ``ClientSessionRecord/connectedSeconds``.
            segmentStartedAt: startedAt,
            path: ConnectionPath.recordPath(of: connectionPath),
            hostID: hostID,
            hostName: hostName ?? String(localized: "A Mac"),
            segmentBytes: activeSessionBytes,
            logs: Array((continuation.logs + activeSessionLogs).suffix(Self.sessionLogLimit)),
            usedDirectPath: usedDirectPath,
            endedDeliberately: userEndedDeliberately
        )
        // **Replaced rather than added to.** The record a drop filed has been in the history for
        // the whole of this session, deliberately, so that a session iOS kills before it ends does
        // not take its own past away with it; and this session is that same row with more time on
        // it. Two entries for one session is the whole of what this is here to stop.
        if activeSessionContinuation != nil {
            model.sessionHistory.removeAll { $0.id == record.id }
        }
        model.sessionHistory.insert(record, at: 0)
        model.sessionHistory = SessionHistoryStore.kept(model.sessionHistory)
        SessionHistoryStore.save(model.sessionHistory)

        activeSessionHistoryID = nil
        activeSessionHistoryStartedAt = nil
        activeSessionBytes = 0
        lastBandwidthSampleBytes = 0
        activeSessionLogs = []
        activeSessionContinuation = nil

        // The offer reads ``SessionModel/relaySecondsRemainingEstimate``, which counts the
        // finished session out of the history *and* the live one out of
        // ``activeSessionDuration`` — so armed before the clear, the session that just ended
        // would be counted twice, and the user would be told they had less relay left than they
        // do. The record is already in `sessionHistory` by this point, which is what makes the
        // figure right rather than merely uncounted.
        model.offerSubscriptionIfDue(after: record)
        model.askForReviewIfDue(after: record)
        return record
    }
}
