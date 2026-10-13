import PeeringKit
import RemoteCore
import SwiftUI

/// An event belongs to the connection that delivered it, so it is applied to that connection's state: an event from one Mac must not move another's picture, phase or terminals. Every mutation is `self.`; only app-wide consequences (notification, Live Activity, history store, reconnect ladder) reach through ``model``.
extension MacSession {
    func apply(_ event: ClientSession.Event) {
        switch event {
        case .phase(let phase):
            apply(phase: phase)
        case .host(let hello):
            apply(hello: hello)
        case .catalog(let catalog):
            apply(catalog: catalog)
        case .video(let event):
            apply(video: event)
        case .latency(let milliseconds):
            latencyMilliseconds = milliseconds
            logLatencyIfDue(milliseconds)
            warnIfConnectionIsVeryBad(milliseconds)
        case .pathLatency(let milliseconds, let fromPeer):
            pathLatencyMilliseconds = milliseconds
            pathLatencyIsDirect = fromPeer
        case .datagramCounts(let counts):
            datagramCounts = counts
        case .note(let message):
            append(note: message)
        case .path(let path):
            // Recorded and deliberately not shown: the session already logs a note when it changes. Not folded into ``connectionPath``: the relay meters by splice time whether or not video went around it, so moving the path off `.relay` would make ``SessionModel/relaySecondsUsedThisPeriod`` under-report sessions the relay still charges for.
            usedDirectPath = path == .direct
        case .directPath(let outcome):
            // The other half: `path` says where the picture is arriving when it works; this says what the attempt came to when it does not. Shown rather than logged because a failure has no note in the session log to find it in.
            directPathStatus = outcome
            append(note: String(localized: "Direct path: \(outcome.summary)"))
        case .remoteNotice(let message):
            remoteNotice = message
            // A locked Mac draws no frames for an application or window, so a session resumed on one would sit paused with no password in reach. Go to the lock screen as Unlock would; the detour restores the source once unlocked.
            if let displayID = message?.lockedDisplayID, isActive, unlockDetour == nil,
               model.activeSourceID != CaptureSource.display(displayID).stableID {
                model.showLockScreen(on: displayID)
            }
            // Unlocked: go back to what Unlock left, unless the user has moved on since.
            if message?.lockedDisplayID == nil, let detour = unlockDetour {
                unlockDetour = nil
                if isActive, activeSourceID == detour.lockScreen.stableID {
                    model.selectSource(detour.returnTo)
                    model.showKeyboard = false
                }
            }
        case .textFocus(let focus):
            if isActive { model.textFocusChanged(focus) }
        case .pointer(let point):
            if isActive { model.hostPointer = HostPointer(point: point, serial: model.hostPointer.serial + 1) }
        case .fieldState(let state):
            if isActive { model.fieldStateChanged(state) }
        case .clipboard(let payload):
            hostClipboard = payload
            clipboardPulling = false
            // Text pulls are filed; pictures are not, deliberately: the history lives in `UserDefaults` and is read at launch, so twelve screenshots would be a hundred megabytes of PNG in a plist. A picture history needs a file store with its own eviction.
            if let text = payload.text { model.rememberClipboard(text) }
        case .audio(let event):
            switch event {
            case .config(let config):
                audioPlayer = RemoteAudioPlayer(config: config)
                // A fresh player per stream, so the preference, plan and whether this is the Mac on screen are handed to each. See ``shouldPlayAudio``: a free user's audio and a background Mac's audio are still sent, and this stops them playing.
                refreshAudioMuteState()
            case .frame(let frame):
                audioPlayer?.enqueue(frame)
            }
        case .terminal(let event):
            apply(terminal: event)
        case .agent(let event):
            apply(agent: event)
        case .hostStopped:
            // Arrives just before the failure it explains, so that failure ends the session instead of arming the ladder against a Mac that is no longer listening.
            userEndedDeliberately = true
            stopReconnecting()
        case .relayRemaining(let seconds):
            model.relayRemainingSecondsFromRelay = RelayRemainingReport(
                seconds: TimeInterval(seconds),
                receivedAt: Date()
            )
        case .relayQuotaExceeded:
            applyRelayQuotaExceeded()
        }
    }
}
