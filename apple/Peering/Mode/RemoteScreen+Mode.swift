import PeeringKit
import RemoteCore
import SwiftUI

extension RemoteScreen {
    @ViewBuilder
    var modeLayers: some View {
        if let session = model.activeSession {
            if session.mode == .remote, session.modeResolved, !showsModePicker {
                RemoteDockView(
                    onSwitchMode: { showsModePicker = true },
                    onShowScreen: { chooseMode(.screen, source: "picker") }
                )
                .transition(.opacity)
            }
            if showsModePicker {
                SessionModePicker(
                    modes: SessionMode.allCases,
                    hostName: model.shownHostName ?? String(localized: "this Mac"),
                    onChoose: { chooseMode($0, source: "picker") },
                    onCancel: session.modeResolved ? { cancelModePicker(in: session) } : nil
                )
                .transition(.opacity)
            }
        }
    }

    private func cancelModePicker(in session: MacSession) {
        showsModePicker = false
        if session.mode == .workspace, route.isEmpty { route = [.hub] }
    }

    /// Opens the mode last chosen for this Mac, or asks. A session that already has a mode (a screen rebuilt, or a dial replaced by a retry) only re-applies it.
    func resolveSessionMode() {
        guard model.phase == .ready, let session = model.activeSession else { return }
        if session.modeResolved {
            applyMode(session.mode)
            return
        }
        switch SessionModeMemory().decision(for: session.hostID, available: SessionMode.allCases) {
        case .open(let mode):
            Analytics.sessionModeChosen(mode, source: "remembered")
            applyMode(mode)
        case .ask:
            showsModePicker = true
        }
    }

    func chooseMode(_ mode: SessionMode, source: String) {
        guard let session = model.activeSession else { return }
        // A mode chosen by hand ends the visit, so the pill cannot later put back a mode the person left.
        watching = nil
        let previous = session.mode
        if let hostID = session.hostID { SessionModeMemory().remember(mode, for: hostID) }
        if session.modeResolved, previous != mode {
            Analytics.sessionModeChanged(from: previous, to: mode)
        } else if !session.modeResolved {
            Analytics.sessionModeChosen(mode, source: source)
        }
        applyMode(mode)
    }

    func applyMode(_ new: SessionMode) {
        guard let session = model.activeSession else { return }
        let old = session.mode
        session.mode = new
        session.modeResolved = true
        // The picker is a screen of its own, so the hub replaces it outright: fading the picker out or sliding the hub in would show the Mac's picture between the two.
        var transaction = Transaction()
        transaction.disablesAnimations = showsModePicker && new == .workspace
        withTransaction(transaction) {
            showsModePicker = false
            if new == .workspace {
                if route.isEmpty { route = [.hub] }
            } else if old == .workspace, !route.isEmpty {
                route = []
            }
        }
        switch SessionModePicture.action(entering: new, pausedByMode: session.picturePausedByMode) {
        case .pause:
            session.picturePausedByMode = !session.picturePaused
            session.setPicturePaused(true)
        case .resume:
            session.picturePausedByMode = false
            session.setPicturePaused(false)
        case .none:
            break
        }
    }

    /// Backing out of the hub goes back to the picker it was opened from. Going straight to the screen showed a picture still paused by the mode, blank until the Mac sent a new keyframe.
    func leaveWorkspaceIfClosed(_ route: [RemoteRoute]) {
        guard route.isEmpty, model.activeSession?.mode == .workspace, !showsModePicker else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { showsModePicker = true }
    }
}
