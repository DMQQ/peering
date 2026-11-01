import PeeringKit
import SwiftUI

extension TerminalHubScreen {
    /// One Mac with a handful of chats is already on this page: the board earns its place with several Macs or a long list.
    @ViewBuilder
    var allChatsEntry: some View {
        if model.openSessions.count > 1 || model.agentCards.count > Self.boardChatThreshold {
            ChatBoardSummary()
                .padding(.top, 12)
        }
    }

    static let boardChatThreshold = 4
}
