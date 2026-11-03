import Foundation
import PeeringKit

extension SessionModel {
    /// Every chat on every Mac that is connected now. A Mac not connected contributes nothing: its last list would be stale.
    var chatBoard: ChatBoard {
        let clock = ChatBoardLedger.shared.clock
        let entries = openSessions.flatMap { session in
            let macName = session.shownName ?? session.hostPlatform.adapt(String(localized: "the Mac"))
            return session.agentCards.map { card in
                ChatBoardEntry(
                    id: card.id,
                    macSessionID: session.id,
                    macName: macName,
                    agentID: card.agentID,
                    title: card.title,
                    snippet: card.preview,
                    state: card.state,
                    isPaused: card.isPaused,
                    changedAt: clock.changedAt(card.id, fallback: card.createdAt),
                    isUnread: clock.isUnread(card.id)
                )
            }
        }
        return ChatBoard(entries)
    }

    /// The same way in as a tapped notification: the Mac is brought forward and the remote screen opens the chat once it is up.
    func openBoardChat(_ entry: ChatBoardEntry) {
        ChatBoardLedger.shared.markSeen(entry.id)
        activateSession(entry.macSessionID)
        isSessionOnScreen = true
        InAppBanner.shared.openRequest = .chat(entry.id)
    }
}
