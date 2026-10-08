import Foundation

/// A file in a chat's changes: enough to find its entry again after a refresh.
public struct AgentReviewTarget: Hashable {
    public let chatID: UUID
    public let path: String

    public init(chatID: UUID, path: String) {
        self.chatID = chatID
        self.path = path
    }
}

extension AgentReviewQueue {
    /// Every file a row is shown for, in list order. A chat the Mac cannot answer for is left out: its list is old.
    public var selectableTargets: [AgentReviewTarget] {
        visibleGroups.filter { $0.status == .current }.flatMap { group in
            group.files.map { AgentReviewTarget(chatID: group.chatID, path: $0.file.path) }
        }
    }

    /// The selection with every file that is no longer on screen taken out, so a filter can never leave a hidden file to be rejected or marked.
    public func retaining(_ selection: Set<AgentReviewTarget>) -> Set<AgentReviewTarget> {
        selection.intersection(selectableTargets)
    }
}
