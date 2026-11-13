import PeeringKit
import RemoteCore
import SwiftUI

extension RemoteScreen {
    var showsRemoteBar: Bool {
        model.activeSession.map { $0.modeResolved && $0.mode == .remote } ?? false
    }

    /// The pushed picture's navigation bar: only Remote shows one, because the Mac's own picture owns the whole screen.
    @ToolbarContentBuilder
    var remoteToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { chooseMode(.screen, source: "picker") } label: { Image(systemName: "macwindow") }
                .accessibilityLabel(String(localized: "Screen"))
        }
    }

    /// Backs out of the mode to the picker, which is what the stack rests on.
    func openModePicker() {
        route = []
    }

    /// Closing the picker returns to the mode it was opened from.
    func closeModePicker() {
        guard let session = model.activeSession else { return }
        move(to: SessionModeFlow.target(for: session.mode), animated: true)
    }

    /// Opens the mode last chosen for this Mac, or asks. A session that already has a mode (a screen rebuilt, or a dial replaced by a retry) only re-applies it.
    func resolveSessionMode() {
        guard model.phase == .ready, let session = model.activeSession else { return }
        let entry = SessionModeFlow.entry(
            modeResolved: session.modeResolved,
            current: session.mode,
            remembered: SessionModeMemory().decision(for: session.hostID, available: SessionMode.allCases)
        )
        switch entry {
        case .reapply(let mode):
            applyMode(mode, animated: false)
        case .open(let mode):
            Analytics.sessionModeChosen(mode, source: "remembered")
            applyMode(mode, animated: false)
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
        applyMode(mode, animated: true)
    }

    /// Not animated when the app puts a mode back on its own (a connect, a retry): sliding in then would show the picker for a moment.
    func applyMode(_ new: SessionMode, animated: Bool = true) {
        guard let session = model.activeSession else { return }
        session.mode = new
        session.modeResolved = true
        showsModePicker = false
        if let target = SessionModeFlow.retarget(entering: new, from: route.target) {
            move(to: target, animated: animated)
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

    private func move(to target: SessionModeFlow.Target, animated: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = !animated
        withTransaction(transaction) { route = .resting(on: target) }
    }
}
