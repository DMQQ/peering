import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import WidgetKit
import os

extension SessionModel {
    // MARK: - Discovery

    func start() {
        guard identityFailure == nil else { return }
        // Anything on the Lock Screen from a previous run describes a session this process did not survive.
        SessionActivity.shared.adoptOrphan()
        LiveActivityTokens.shared.deliver = { [weak self] payload in
            self?.activeSession?.wire?.sendActivityToken(payload)
        }
        LiveActivityTokens.shared.startObservingPushToStart()
        browser.onEvent = { [weak self] event in
            // Bound once outside the `Task`: a `weak self` is a mutable variable and reading it from an outliving closure is a data race.
            guard let self else { return }
            // HostBrowser reports from its own queue, and each of these touches observable state.
            Task { @MainActor in self.apply(event) }
        }

        // Started with the app, not at the first drop: the watcher compares against the path of the last dial, so one begun at a drop would call its first update a change.
        let watcher = NetworkPathWatcher()
        watcher.hasSomethingToPutBack = { [weak self] in
            self?.sessions.contains { $0.isResumingAfterDrop } ?? false
        }
        watcher.onUsableChange = { [weak self] in self?.networkChanged() }
        watcher.onPathChange = { [weak self] in self?.verifyLiveSessions() }
        networkWatcher = watcher
        watcher.start()
    }

    /// For the moment a wait begins, not when the network moves (the relay case). Deferred by a turn at the call site, because it can dial.
    func considerNetworkChange() {
        networkWatcher?.judgeNow()
    }

    /// Only for a Mac on its way back.
    /// The counter is deliberately not reset, which keeps the ladder finite on a phone whose network flaps; dialling early costs a rung, not the ladder.
    private func networkChanged() {
        for session in sessions where session.isResumingAfterDrop {
            session.stopReconnecting()
            session.resumeIfNeeded()
        }
    }

    /// Asks every connected Mac to answer now, so a connection that died with the old network or suspension is redialled at once rather than after the silence watchdog.
    func verifyLiveSessions() {
        for session in sessions where session.phase == .ready {
            session.wire?.verifyStillAnswering()
            if !session.isVideoStreaming {
                session.wire?.retryVideoAfterNetworkChange()
            }
        }
    }

    func startBrowsing() {
        browser.start()
    }

    func restartBrowsing() {
        browseStatus = String(localized: "Looking for Macs on this network…")
        browser.stop()
        browser.start()
    }

    /// Any Mac, not the one on screen: gating on the active session's phase would enable the row the moment the user looked at a Mac that had finished.
    var isBusy: Bool { hasOpenSession }

    func connect(to target: ClientSession.Target) {
        connect(to: target, replacing: nil)
    }

    /// Written out rather than asked of `ClientSession/Target`, whose answer is internal to `RemoteCore`.
    static func hostID(of target: ClientSession.Target) -> String? {
        switch target {
        case .discovered(let host): return host.id
        case .relay(let hostID, _, _), .relayPairing(let hostID, _, _): return hostID
        case .address: return nil
        }
    }
}
