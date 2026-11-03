import PeeringKit
import SwiftUI

extension RemoteScreen {
    /// Not ``chooseMode(_:source:)``: watching is a visit, so the remembered mode for this Mac stays as it was.
    func watchOnMac(from chatID: UUID) {
        guard let session = model.activeSession else { return }
        let watch = ChatWatch(chatID: chatID, sessionID: session.id, previousMode: session.mode)
        watching = watch
        if session.mode != watch.watchingMode { applyMode(watch.watchingMode) }
        route = []
    }

    func returnToChat() {
        guard let watch = watching else { return }
        guard watch.isStillWatching(activeSessionID: model.activeSessionID) else {
            watching = nil
            return
        }
        watching = nil
        if let mode = watch.modeToRestore { applyMode(mode) }
        model.selectedAgentSessionID = watch.chatID
        route = [.hub, .step(.chat(watch.chatID))]
    }

    /// Opening the hub any other way ends the visit, so the pill never offers a chat the person has left.
    func endWatchIfHubOpened(_ route: [RemoteRoute]) {
        if !route.isEmpty { watching = nil }
    }

    func endWatchIfMacChanged() {
        guard let watch = watching, !watch.isStillWatching(activeSessionID: model.activeSessionID) else { return }
        watching = nil
    }

    @ViewBuilder
    var backToChat: some View {
        if watching != nil, route.isEmpty {
            BackToChatPill { returnToChat() }
                // Below the status pill: closer, the two read as one control.
                .padding(.top, 88)
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
