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
    ///
    /// **This segment of it, not the record it belongs to.** A record continued across a drop
    /// covers a span with the gap in it, and the half of the session that has already happened is
    /// still in the history, as the very record this one continues: counting it here as well would
    /// charge the relay for the same minutes twice. See ``SessionContinuation``.
    var activeSessionDuration: TimeInterval {
        guard let activeSessionHistoryStartedAt else { return 0 }
        return Date().timeIntervalSince(activeSessionHistoryStartedAt)
    }

    /// Opens the record for the session that has just come up, or takes up the one a drop filed.
    ///
    /// - Parameter resuming: whether this Mac's session had already come up before this attempt,
    ///   which is the whole of the difference between a reconnect and a connection. When it had,
    ///   the record the drop filed is continued, and the Sessions tab keeps the one row the user
    ///   was looking at rather than growing a second one beside it.
    ///
    /// **The attempt and not the session that preceded it.** A session iOS killed the app with is
    /// not one this can be true of: the process that held it is gone, the app that comes back is
    /// opening a Mac rather than putting a session back, and it files a record of its own. The
    /// alternative would be a row spanning however long the app was closed, which is a session the
    /// user did not have.
    ///
    /// The rule itself, and the facts it refuses on, are ``SessionContinuation``: this is the
    /// question and the history, and nothing else.
    func beginSessionHistory(resuming: Bool) {
        guard activeSessionHistoryID == nil else { return }
        // This segment's own id, which is the record's when the record is a new one. A continued
        // record keeps the id it already had; nothing outside this file reads either.
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

    /// Files the session that has just ended, and asks whether it is worth an offer.
    ///
    /// Returns the record it filed, or `nil` when there was nothing to file — which is the case
    /// for a connection that never reached `.ready`, since ``beginSessionHistory(resuming:)`` is
    /// what creates the session this reads. Callers are free to ignore the result; the offer is
    /// made here rather than at each of them because both teardown paths want it and neither wants
    /// to know about it.
    ///
    /// **A session that was put back after a drop is filed as the record it continued**, which is
    /// the row the user already had rather than a second one beside it: the same identity, the same
    /// start, its bytes and its log carried forward, and the gap it was not connected for in the
    /// span but not in the meter. See ``SessionContinuation``.
    ///
    /// `@discardableResult` rather than changing the two call sites: this is the one funnel every
    /// ended session passes through, and a hook that has to be remembered at each caller is a hook
    /// that will be missed at the third.
    @discardableResult
    func finishSessionHistory() -> ClientSessionRecord? {
        guard let id = activeSessionHistoryID,
              let startedAt = activeSessionHistoryStartedAt else { return nil }
        captureSessionBandwidth()

        let endedAt = Date()
        // A session that never dropped is a continuation of nothing, and it is filed through the
        // same door as one that did, so that the two cannot come to disagree about what a record
        // is: the span it covers, the seconds it was up for, and the bytes it carried.
        let continuation = activeSessionContinuation
            ?? SessionContinuation(id: id, startedAt: startedAt)
        let record = continuation.filed(
            endedAt: endedAt,
            // **The start of this segment, which is not the record's start.** The record's own
            // start is the continuation's, and the distance between the two is the gap: it is what
            // the row's duration is for the user to read, and what the connected seconds stay out
            // of. See ``ClientSessionRecord/connectedSeconds``.
            segmentStartedAt: startedAt,
            // Filed beside the path rather than folded into it: the relay bills this session
            // either way, so `path` stays what the allowance is counted by. See the note on
            // ``ClientSessionRecord/usedDirectPath``.
            path: ConnectionPath.recordPath(of: connectionPath),
            hostID: hostID,
            hostName: hostName ?? "A Mac",
            segmentBytes: activeSessionBytes,
            // The two logs joined, and cut to the same ceiling a session keeps while it is up:
            // a record continued across several drops would otherwise grow by a segment's worth
            // of notes every time, in a store that is read back at launch.
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
        if model.sessionHistory.count > 30 {
            model.sessionHistory.removeLast(model.sessionHistory.count - 30)
        }
        SessionHistoryStore.save(model.sessionHistory)

        activeSessionHistoryID = nil
        activeSessionHistoryStartedAt = nil
        activeSessionBytes = 0
        lastBandwidthSampleBytes = 0
        activeSessionLogs = []
        activeSessionContinuation = nil

        // Last, and after the lines above rather than before them.
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
