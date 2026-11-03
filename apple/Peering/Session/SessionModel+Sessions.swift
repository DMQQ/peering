import Foundation
import PeeringKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import WidgetKit
import os

extension SessionModel {
    /// The cheap one: only which Mac's picture is decoded changes; the Mac left is asked to pause.
    /// A no-op for the session already on screen, deliberately: asking for its picture again would blink it.
    func activateSession(_ id: UUID) {
        guard id != activeSessionID else {
            returnToSession()
            return
        }
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        // Stopped before the switch: otherwise both Macs stream for the handover.
        activeSession?.setPicturePaused(true)
        let left = activeSession
        activeSessionID = id
        session.setPicturePaused(false)
        // Arriving at a Mac is being on its screen, and a pause taken for stepping away went with the old screen.
        isSessionOnScreen = true
        pausedBySteppingAway = false

        // The sound follows the tab: a player for the Mac on screen keeps playing after the user looks away unless told.
        left?.refreshAudioMuteState()
        session.refreshAudioMuteState()

        // Only the Mac the card follows pushes to it, so the one left is told to stop and the one arrived at is given the tokens.
        LiveActivityTokens.shared.release(left?.wire)
        LiveActivityTokens.shared.sendAll(to: session.wire)

        // Its own entry point rather than a phase change: the Mac arrived at has its own clock.
        SessionActivity.shared.followActiveSession(
            hostName: session.shownName ?? session.hostPlatform.adapt(String(localized: "the Mac")),
            startedAt: session.sessionStartedAt,
            phase: session.phase,
            reconnecting: session.isReconnecting,
            path: MacSession.activityPath(session.connectionPath),
            sessionCount: openSessions.count
        )
        publishOpenMacs()
        session.publishWork()
    }

    /// Nothing is sent that could not be sent back, unlike `disconnect(deliberate:)`.
    /// The pause is taken only if the user had not already asked for one and nothing else watches: a picture floating in PiP keeps arriving. A Mac too old to be asked for silence streams at nobody, the honest failure.
    func stepAwayFromSession() {
        guard isSessionOnScreen, let session = activeSession else { return }
        isSessionOnScreen = false
        if !session.picturePaused, !session.isWatched {
            pausedBySteppingAway = true
            session.setPicturePaused(true)
        }
        session.refreshAudioMuteState()
    }

    func returnToSession() {
        guard !isSessionOnScreen, let session = activeSession else { return }
        isSessionOnScreen = true
        if pausedBySteppingAway {
            pausedBySteppingAway = false
            session.setPicturePaused(false)
        }
        session.refreshAudioMuteState()
    }
}
