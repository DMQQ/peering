import Foundation
import MacCastKit

/// One Mac's session, as a record.
///
/// **Per session, and filed app-wide.** The record this builds already carries a `hostID`, so
/// the list of finished sessions is naturally one list across every Mac — what was per Mac was
/// only ever the session *in flight*, which is what this file holds. See
/// ``SessionModel/finishSessionHistory`` for the half that stays on the model.
extension MacSession {
    /// How long this session has been up, or zero before it came up.
    var activeSessionDuration: TimeInterval {
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
    /// Returns the record it filed, or `nil` when there was nothing to file — which is the case
    /// for a connection that never reached `.ready`, since ``beginSessionHistory()`` is what
    /// creates the session this reads. Callers are free to ignore the result; the offer is made
    /// here rather than at each of them because both teardown paths want it and neither wants to
    /// know about it.
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
            hostID: hostID,
            hostName: hostName ?? "A Mac",
            startedAt: startedAt,
            endedAt: Date(),
            path: ConnectionPath.recordPath(of: connectionPath),
            videoBytesReceived: activeSessionBytes,
            logs: activeSessionLogs,
            // Filed beside the path rather than folded into it: the relay bills this session
            // either way, so `path` stays what the allowance is counted by. See the note on
            // ``ClientSessionRecord/usedDirectPath``.
            usedDirectPath: usedDirectPath
        )
        model.sessionHistory.insert(record, at: 0)
        if model.sessionHistory.count > 30 {
            model.sessionHistory.removeLast(model.sessionHistory.count - 30)
        }
        SessionHistoryStore.save(model.sessionHistory)

        activeSessionHistoryID = nil
        activeSessionHistoryStartedAt = nil
        activeSessionBytes = 0
        lastBandwidthSampleBytes = 0
        activeSessionLogs = []

        // Last, and after the five lines above rather than before them.
        //
        // The offer reads ``SessionModel/relaySecondsRemainingEstimate``, which counts the
        // finished session out of the history *and* the live one out of
        // ``activeSessionDuration`` — so armed before the clear, the session that just ended
        // would be counted twice, and the user would be told they had less relay left than they
        // do. The record is already in `sessionHistory` by this point, which is what makes the
        // figure right rather than merely uncounted.
        model.offerSubscriptionIfDue(after: record)
        return record
    }
}
