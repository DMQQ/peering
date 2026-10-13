import PeeringKit
import RemoteCore
import SwiftUI

extension AgentChatScreen {
    /// A mention is only offered where the Mac's folders can be read: the same door the attachments use.
    func mentionQuery(_ session: RemoteAgentSession) -> MentionQuery? {
        guard model.browserID != nil, model.hostSupportsFileBrowser else { return nil }
        return MentionQuery(draft: drafts[session.id] ?? "")
    }

    /// Nil unless the message is one word starting with a slash.
    func slashItems(_ session: RemoteAgentSession) -> [SlashSuggestion]? {
        guard let typed = AgentSlash.query(drafts[session.id] ?? "") else { return nil }
        return AgentSlash.suggestions(
            for: typed,
            agentID: session.agentID,
            project: session.directory,
            offersUsage: model.hostSupportsAgentUsage,
            offersModel: offersModelPicker(session),
            listing: { path in model.browserID.flatMap { model.directory(path, sessionID: $0) }?.entries }
        )
    }

    func runSlash(_ item: SlashSuggestion, in session: RemoteAgentSession) {
        guard item.kind == .app else {
            drafts[session.id] = "/" + item.name + " "
            return
        }
        drafts[session.id] = ""
        switch item.name {
        case "usage": showsUsage = true
        case "model":
            modelText = session.model ?? ""
            typingModelFor = session.id
        default: beginRename(session)
        }
    }

    var draft: Binding<String> {
        Binding(
            get: { drafts[currentID] ?? "" },
            set: { drafts[currentID] = $0 }
        )
    }

    func send(_ session: RemoteAgentSession) {
        // Typed out in full and sent: the app answers its own commands instead of handing them to the CLI.
        if let typed = AgentSlash.query(drafts[session.id] ?? ""),
           let item = slashItems(session)?.first(where: { $0.kind == .app && $0.name == typed }) {
            runSlash(item, in: session)
            return
        }
        let text = AgentDraft.prompt(
            draft: drafts[session.id] ?? "",
            attachedPaths: (attached[session.id] ?? []).filter { $0.failure == nil }.map(\.path)
        )
        drafts[session.id] = ""
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { attached[session.id] = nil }
        stickToBottom = true
        model.sendAgentPrompt(text, to: session.id)
    }

    func follow(up suggestion: AgentFollowUps.Suggestion, in session: RemoteAgentSession) {
        switch suggestion {
        case .reviewChanges:
            showsChanges = true
        case .runTests:
            stickToBottom = true
            model.sendAgentPrompt("Run the project's tests and fix anything that fails.", to: session.id)
        case .summarizeChanges:
            stickToBottom = true
            model.sendAgentPrompt("Summarize what you changed and why, file by file.", to: session.id)
        }
    }
}
