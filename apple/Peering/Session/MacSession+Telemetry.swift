import Foundation
import MacCastKit
import RemoteCore
import UIKit

/// What a Mac's session remembers for analytics and for the retry cap, carried across the new object each automatic retry builds.
struct SessionTelemetry {
    /// New for every manual connect and kept across automatic resumes, so both ends' events for one session share it.
    let sessionRef = SessionRef.make()
    var routes = RouteAttemptLog()
    var dropStreak = DropStreak()
    var tally = SessionTally()
    var networkChangesAtStart = 0
    /// Set when a ready session drops and is being put back; the end is reported if the ladder gives up, and forgotten if it succeeds.
    var pendingEnd: SessionEndReason?
    var endReported = false
    /// Whether a connected stretch is open, so closing it twice cannot count it twice.
    var isStretchOpen = false
    var lastStretchSeconds: TimeInterval = 0

    /// For an automatic retry: the session continues, so its tallies do. The streak goes too, which is what lets the cap see consecutive drops.
    func carriedToRetry() -> SessionTelemetry {
        var next = self
        next.endReported = false
        next.isStretchOpen = false
        return next
    }
}

extension RouteAttemptLog.Route {
    init(_ path: ConnectionPath?) {
        switch path {
        case .relay: self = .relay
        case .direct: self = .address
        case .lan, .none: self = .lan
        }
    }
}

extension MacSession {
    func beginRoute(_ route: RouteAttemptLog.Route) {
        telemetry.routes.begin(route)
    }

    func noteRouteFailed(_ path: ConnectionPath, reason: ClientSession.FailureReason?) {
        telemetry.routes.finish(.init(path), outcome: (reason ?? .other).rawValue)
    }

    /// Called as a ready session leaves `.ready`, before the history record is filed and clears the figures read here.
    func closeStretch() {
        guard telemetry.isStretchOpen else { return }
        telemetry.isStretchOpen = false
        captureSessionBandwidth()
        let ran = sessionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        telemetry.lastStretchSeconds = ran
        telemetry.tally.addStretch(seconds: ran, videoBytes: activeSessionBytes, droppedFrames: renderer.currentSnapshot.framesDropped)
    }

    func noteReady(hadBeenReady: Bool) {
        telemetry.routes.finish(.init(connectionPath), outcome: RouteAttemptLog.succeeded)
        telemetry.isStretchOpen = true
        telemetry.pendingEnd = nil
        if hadBeenReady {
            telemetry.tally.noteReconnect()
            return
        }
        telemetry.networkChangesAtStart = model.networkContext.pathChanges
        Analytics.sessionStarted(
            path: (connectionPath ?? .lan).rawValue,
            plan: model.storeManager.access.plan,
            millisecondsToReady: wire?.millisecondsToReady,
            telemetry: ConnectionTelemetry.properties(for: connectionContext(), diagnosis: nil).merging(refProperty) { $1 }
        )
    }

    /// The failed phase a capped session shows in place of the one the wire sent, or `nil` to carry on retrying. The retries stop here and the person is told why; a manual connect builds a fresh session and so starts the count again.
    func retryCapFailure(for phase: ClientSession.Phase) -> ClientSession.Phase? {
        guard case .failed = phase, let wire, let reason = wire.failureReason else { return nil }
        let pictureSeconds = DropStreak.pictureSeconds(
            ranSeconds: telemetry.lastStretchSeconds,
            firstPictureMilliseconds: wire.videoDeliveryRecord.firstPictureMilliseconds,
            lastFrameAgeMilliseconds: wire.failureDiagnosis?.lastFrameAgeMilliseconds
        )
        let verdict = telemetry.dropStreak.sessionEnded(
            reason: reason, ranSeconds: telemetry.lastStretchSeconds, pictureSeconds: pictureSeconds
        )
        guard verdict == .stop else { return nil }
        UserDefaults.standard.set(false, forKey: SessionModel.resumeKey)
        isComingBack = false
        return .failed(String(localized: "Connection keeps dropping. Check that the computer is awake and on a good network, then try again."))
    }

    /// For a ready session that failed: ends it now when nothing will retry, otherwise leaves the verdict to the ladder.
    func noteDropped(capped: Bool) {
        let reason = capped ? SessionEndReason.retryCapped : SessionEndReason(failure: wire?.failureReason ?? .other)
        if capped || userEndedDeliberately {
            reportEnd(reason)
        } else {
            telemetry.pendingEnd = reason
        }
    }

    func reportConnectFailure(appState: String) {
        let reason = wire?.failureReason
        telemetry.routes.finish(.init(connectionPath), outcome: (reason ?? .other).rawValue)
        Analytics.connectFailed(
            afterReady: hasBeenReady,
            reason: reason?.rawValue ?? "unknown",
            path: (connectionPath ?? .lan).rawValue,
            reconnectAttempt: model.reconnectAttempt,
            secondsIntoSession: sessionStartedAt.map { Int(Date().timeIntervalSince($0)) },
            appState: appState,
            pictureInPictureActive: SessionPiP.shared.isActive,
            video: wire?.videoDeliveryRecord,
            consecutiveDrops: telemetry.dropStreak.count,
            telemetry: ConnectionTelemetry.properties(for: connectionContext(), diagnosis: wire?.failureDiagnosis).merging(refProperty) { $1 }
        )
        if let reason, let pairing = PhoneFailure.pairingFailure(reason: reason, stage: wire?.failureDiagnosis?.stage ?? .connecting) {
            Analytics.pairingFailed(stage: pairing.stage, reason: pairing.reason, sessionRef: telemetry.sessionRef)
        }
    }

    /// Once per session, and only for one that reached ready: a dial the user cancelled was never a session.
    func reportEnd(_ reason: SessionEndReason) {
        guard hasBeenReady, !telemetry.endReported else { return }
        telemetry.endReported = true
        closeStretch()
        var properties = ConnectionTelemetry.properties(for: connectionContext(), diagnosis: nil).merging(refProperty) { $1 }
        properties.merge(ConnectionTelemetry.endProperties(
            reason: reason,
            durationSeconds: telemetry.tally.seconds,
            reconnects: telemetry.tally.reconnects,
            videoBytes: telemetry.tally.videoBytes,
            droppedFrames: telemetry.tally.droppedFrames
        )) { _, new in new }
        Analytics.sessionEnded(path: connectionPath?.rawValue ?? "unknown", video: wire?.videoDeliveryRecord, telemetry: properties)
    }

    private var refProperty: [String: any Sendable] { ["session_ref": telemetry.sessionRef] }

    private func connectionContext() -> ConnectionTelemetry.Context {
        let network = model.networkContext
        return ConnectionTelemetry.Context(
            routes: telemetry.routes.summary,
            network: network,
            networkChangesDuringSession: network.changes(since: telemetry.networkChangesAtStart),
            hostPlatform: wire?.serverHello?.hostPlatform,
            quotaBucket: quotaBucket()
        )
    }

    /// Only a relayed session spends the allowance.
    private func quotaBucket() -> String? {
        guard connectionPath == .relay else { return nil }
        let plan = model.storeManager.access.plan ?? .free
        let remaining = plan.allowanceSeconds.map { max(0, $0 - model.relaySecondsUsedThisPeriod) }
        return ConnectionBuckets.quotaRemaining(remaining)
    }
}
