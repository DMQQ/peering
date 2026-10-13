import RemoteCore
import SwiftUI

/// The peek of a conversation that lives only on the Mac: asked for when the menu opens, shown when it arrives.
struct ResumableChatPeek: View {
    let conversation: AgentResumableSession
    @Environment(SessionModel.self) private var model

    var body: some View {
        AgentChatPeek(title: conversation.title, directory: conversation.directory, session: model.resumablePeek(conversation))
            .task { model.peekResumableSession(conversation) }
    }
}
