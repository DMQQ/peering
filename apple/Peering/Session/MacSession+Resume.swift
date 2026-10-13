import Foundation
import PeeringKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import os

extension MacSession {
    /// Neither the phase nor ``isLive`` can tell a drop from a first connection, or one just landed from a ladder that has run out; `hasGivenUpResuming` is that distinction. The rule lives in ``SessionResume``, where it can be tested.
    var isResumingAfterDrop: Bool {
        SessionResume.isUnderWay(
            hasBeenReady: hasBeenReady,
            userEndedDeliberately: userEndedDeliberately,
            hasGivenUpResuming: hasGivenUpResuming,
            isReconnecting: isReconnecting,
            phase: phase
        )
    }

    /// `.ready` is excluded by name because every other flag stays true through it. The user's word ends it: `isComingBack` is cleared only where a ladder runs out, so a Quit tapped mid-resume left the screen saying it was reconnecting with nothing to press to leave.
    var isBeingPutBack: Bool {
        guard phase != .ready, !userEndedDeliberately else { return false }
        return isResumingAfterDrop || isComingBack
    }

    private var hasReconnectWindowPassed: Bool {
        guard let began = reconnectingSince else { return false }
        return ContinuousClock.now - began >= .seconds(SessionModel.reconnectWindow)
    }

    /// The `wire == nil` guard stops the retry and the browser both starting an attempt, since the wire is assigned synchronously in ``SessionModel/connect(to:)``.
    func resumeIfNeeded() {
        CrashLog.note("resume check · \(hostID ?? "unknown") · phase \(phase) · attempt \(reconnectAttempt)")
        guard wire == nil, !phase.holdsSession else {
            if phase.holdsSession { stopReconnecting() }
            return
        }
        // Only a Mac that was actually connected: an attempt that failed at the handshake has ended, and the failure card is for that.
        guard hasBeenReady || isReconnecting else { return }
        guard UserDefaults.standard.bool(forKey: SessionModel.resumeKey) else {
            // Nothing will put this Mac back, so clear the claim: otherwise `isReconnecting` stays set with no task behind it and the Mac holds a session slot and tab for the rest of the launch.
            stopReconnecting()
            return
        }
        guard let hostID else {
            // No handshake means no Mac to dial (a mistyped first pairing ID), so nothing to retry.
            stopReconnecting()
            return
        }

        if let host = model.hosts.first(where: { $0.id == hostID }) {
            stopReconnecting()
            model.isResuming = true
            model.reconnect(self, to: .discovered(host))
        } else if let remembered = model.rememberedLANHost(hostID) {
            // Every rung tries the LAN, racing the relay: Bonjour not listing the Mac is the expected state of a resume (the Mac withdraws while a phone is connected), so the last good address is dialled first and the relay joins a moment later. See ``DialRace``.
            stopReconnecting()
            model.isResuming = true
            let relay = model.allowsRelay && model.pins.hostIDs.contains(hostID)
                ? model.relayTarget(hostID: hostID, name: hostName ?? String(localized: "A Mac"))
                : nil
            model.reconnect(
                self,
                to: .discovered(remembered),
                timeout: SessionModel.rememberedPathTimeout,
                racingRelay: relay
            )
        } else if model.allowsRelay, model.pins.hostIDs.contains(hostID) {
            stopReconnecting()
            model.isResuming = true
            model.reconnect(self, to: model.relayTarget(hostID: hostID, name: hostName ?? String(localized: "A Mac")))
        } else {
            // The LAN-only case: the Mac is paired and not here yet. Stopping at the first attempt that found nothing would end a resume that has not failed.
            scheduleReconnect()
        }
    }

    /// The wait is a wall clock and the app is not running for most of it, so a phone put away mid-resume comes back with part of a rung spent. Called as the app comes to the front.
    /// Only where the Mac can be dialled from where it stands: otherwise cutting the wait short would spend the rung rather than skip it.
    func resumeWithoutWaiting() {
        guard reconnectTask != nil, let hostID else { return }
        let visible = model.hosts.contains { $0.id == hostID }
        // A remembered address counts as dialable: a phone coming to the front has stale Bonjour results.
        let remembered = model.rememberedLANHost(hostID) != nil
        let byRelay = model.allowsRelay && model.pins.hostIDs.contains(hostID)
        guard visible || remembered || byRelay else { return }
        stopReconnecting()
        resumeIfNeeded()
    }

    /// A resume gets the shorter ladder, chosen here because it must match the counter: `reconnectAttempt` indexes into whichever ladder is used.
    func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        // A Mac already given up on is not dialled again: the window can end an episode before the counter runs out, and the failures from the attempt it cut would start the ladder over.
        guard !hasGivenUpResuming else { return }
        // Not `isResumingAfterDrop`, which reads `isReconnecting`, only set below: at the moment of a drop it is false and the drop would get the slow ladder.
        let resuming = hasBeenReady && !userEndedDeliberately
        let delays = resuming
            ? SessionModel.resumeReconnectDelays
            : SessionModel.reconnectDelays
        // The clock starts at the first rung and is carried across every dial, so it measures the episode, not the attempt.
        if hasBeenReady, reconnectingSince == nil { reconnectingSince = .now }
        guard reconnectAttempt < delays.count, !hasReconnectWindowPassed else {
            giveUpOnReconnecting()
            return
        }
        let delay = delays[reconnectAttempt]
        reconnectAttempt += 1
        logEvent("Reconnecting: attempt \(reconnectAttempt) of \(delays.count) in \(delay.formatted())")
        isReconnecting = true
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            // Coming back to the front dials: `SessionModel.enteringForeground()` runs `resumeIfNeeded()` for every Mac.
            guard BackgroundRedial.mayDialFromTimer(
                appIsBackground: UIApplication.shared.applicationState == .background,
                pictureInPictureIsActive: SessionPiP.shared.isActive
            ) else {
                CrashLog.note("redial held until the app is in front · \(self.hostID ?? "unknown")")
                return
            }
            self.resumeIfNeeded()
        }

        // The phone's network may have moved unnoticed (nothing was being put back) and a relay socket can hang for the whole silence watchdog. Asked here because this is the only place a wait begins, deferred a turn because the answer can dial. Only for a Mac being put back.
        if isResumingAfterDrop {
            Task { @MainActor [model] in model.considerNetworkChange() }
        }
    }

    /// See ``SessionModel/stopReconnecting()`` for why the counter is not cleared here.
    func stopReconnecting() {
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
    }

    /// Called from the poll this session runs while being put back, the one thing still ticking when a dial has stopped answering: every other end is reached by a failure arriving, and a Mac that never answers sends none.
    func giveUpAfterReconnectWindow() {
        guard hasReconnectWindowPassed else { return }
        sessionLog.error("no answer from the Mac in \(Int(SessionModel.reconnectWindow))s, giving up")
        giveUpOnReconnecting()
    }

    /// One end for both ways a ladder finishes: out of rungs, or out of time.
    private func giveUpOnReconnecting() {
        logEvent("Gave up reconnecting")
        reportEnd(telemetry.pendingEnd ?? .error)
        stopReconnecting()
        reconnectingSince = nil
        // A restoration that never got its answer ends like one that failed: the persisted request goes, so the next launch does not open this again.
        if !hasBeenReady, isComingBack {
            UserDefaults.standard.set(false, forKey: SessionModel.resumeKey)
        }
        // And the flag a cold launch set: nothing will dial this Mac again this launch, so the header would describe an attempt that no longer exists.
        isComingBack = false
        // Running out is when the app stops behaving like a session coming back: this flag turns the remote screen over to the picker. The banner is not re-posted because `SessionAwareness` refuses a repeat of the phase it is in.
        hasGivenUpResuming = true
        gaveUpAt = MonotonicStamp()
        // A dial still in flight is ended here; it reports `.disconnected`, which the guard at the top of ``scheduleReconnect()`` stops from arming another rung.
        connectTask?.cancel()
        connectTask = nil
        dialRace?.cancel()
        wire?.disconnect()
        wire = nil
        // The app started the attempt just cut, so the flag goes with it: left set, the user's next dial of any Mac would read as ours.
        model.clearResumingIfNothingIsUnderWay()
        // The screen is about to leave and no replacement stream will reuse its display, so this releases the attachment that non-deliberate teardown kept for the retry. A background Mac shares the active Mac's renderer and must not detach it.
        if isActive { renderer.detach() }
        // The Live Activity must be told directly: a ladder running out changes no phase, so `sessionMoved` never runs and the card would stay on Reconnecting. Only for the Mac on screen.
        if isActive {
            SessionActivity.shared.sessionDropped(
                hostName: shownName ?? String(localized: "the Mac"),
                startedAt: nil,
                path: Self.activityPath(connectionPath)
            )
        }
    }
}
