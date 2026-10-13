import Foundation

/// What "send all issues" will do: one prompt per chat, each with only that chat's comments.
public struct AgentReviewSendPlan: Equatable {
    public struct Item: Equatable, Identifiable {
        public var id: UUID { chatID }
        public let chatID: UUID
        public let title: String
        public let commentCount: Int
        public let prompt: String
    }

    public let items: [Item]

    public init(chats: [(id: UUID, title: String, comments: [AgentReviewComment])]) {
        items = chats.compactMap { chat in
            guard !chat.comments.isEmpty else { return nil }
            return Item(
                chatID: chat.id, title: chat.title, commentCount: chat.comments.count,
                prompt: AgentReviewPrompt.text(for: chat.comments)
            )
        }
    }

    public var commentCount: Int { items.reduce(0) { $0 + $1.commentCount } }

    /// One line per chat for the confirmation.
    public var summary: String {
        items.map { String(localized: "\($0.commentCount) to \($0.title)") }.joined(separator: "\n")
    }
}
