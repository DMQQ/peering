import Foundation

/// What "send back to fix" will do: one prompt per chat that owns a selected file.
public struct AgentReviewRejection: Equatable {
    public struct Item: Equatable, Identifiable {
        public var id: UUID { chatID }
        public let chatID: UUID
        public let title: String
        public let paths: [String]
        /// The comments that went into the prompt, to clear once it is sent.
        public let commentIDs: [UUID]
        public let prompt: String

        public var fileCount: Int { paths.count }
    }

    /// The most the list of paths may take, so the comments keep the rest of the host's limit.
    static let maximumFileListBytes = 16 * 1024

    public let items: [Item]

    public init(
        chats: [(id: UUID, title: String, comments: [AgentReviewComment])], selection: Set<AgentReviewTarget>
    ) {
        items = chats.compactMap { chat in
            let paths = selection.filter { $0.chatID == chat.id }.map(\.path)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            guard !paths.isEmpty else { return nil }
            let chosen = Set(paths)
            let comments = chat.comments.filter { chosen.contains($0.path) }
            return Item(
                chatID: chat.id, title: chat.title, paths: paths, commentIDs: comments.map(\.id),
                prompt: Self.prompt(paths: paths, comments: comments)
            )
        }
    }

    public var fileCount: Int { items.reduce(0) { $0 + $1.fileCount } }

    /// One line per chat for the confirmation. Inflection is markdown, which only an attributed string resolves.
    public var summary: String {
        items.map { String(AttributedString(localized: "^[\($0.fileCount) file](inflect: true) to \($0.title)").characters) }
            .joined(separator: "\n")
    }

    private static func prompt(paths: [String], comments: [AgentReviewComment]) -> String {
        var text = String(localized: "These files were sent back in review. Please fix them.") + "\n\n" + String(localized: "Files:")
        var left = 0
        for path in paths {
            let line = "\n- " + path
            if left > 0 || text.utf8.count + line.utf8.count > maximumFileListBytes {
                left += 1
                continue
            }
            text += line
        }
        if left > 0 { text += "\n" + String(localized: "\(left) more files are not listed.") }

        let commented = Set(comments.map(\.path))
        var closing = ""
        if paths.contains(where: { !commented.contains($0) }) {
            closing = "\n\n" + String(localized: "Files without a comment were rejected without a note. Re-check them and fix whatever is wrong.")
        }
        if !comments.isEmpty {
            let room = AgentReviewPrompt.maximumBytes - text.utf8.count - closing.utf8.count - 2
            text += "\n\n" + AgentReviewPrompt.text(for: comments, limit: room)
        }
        return text + closing
    }
}
