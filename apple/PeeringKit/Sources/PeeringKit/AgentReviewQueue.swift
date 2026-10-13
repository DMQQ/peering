import Foundation
import RemoteCore

/// What the review list knows about one chat's changes, and how far to trust it.
public struct AgentReviewSource: Equatable {
    public let chatID: UUID
    public let title: String
    public let directory: String
    public let report: AgentChangesReport?
    /// Whether the Mac is answering right now. Without it a held report is a last-known one.
    public let isReachable: Bool
    public let isLoading: Bool

    public init(chatID: UUID, title: String, directory: String, report: AgentChangesReport?, isReachable: Bool, isLoading: Bool = false) {
        self.chatID = chatID
        self.title = title
        self.directory = directory
        self.report = report
        self.isReachable = isReachable
        self.isLoading = isLoading
    }
}

public struct AgentReviewFile: Equatable, Identifiable {
    public var id: String { file.path }
    public let file: AgentChangedFile
    public let isReviewed: Bool
}

public struct AgentReviewGroup: Equatable, Identifiable {
    public enum Status: Equatable {
        /// A current answer: ``files`` can be counted.
        case current
        /// The Mac has not answered for this chat yet.
        case unknown
        case checking
        /// The Mac cannot be reached, so any report held is old and is not counted.
        case unreachable
        /// The answer is that there is nothing git can compare.
        case notRepository
    }

    public var id: UUID { chatID }
    public let chatID: UUID
    public let title: String
    public let directory: String
    public let status: Status
    public let files: [AgentReviewFile]
    /// Files the filter took out of ``files``; they are not pending.
    public let hiddenCount: Int

    public var pendingFiles: [AgentReviewFile] { files.filter { !$0.isReviewed } }
    public var pendingCount: Int { status == .current ? pendingFiles.count : 0 }
    public var pendingStats: AgentChangeStats {
        status == .current ? AgentChangeStats(files: pendingFiles.map(\.file)) : .empty
    }
}

/// The files across all open chats that await a look, grouped by chat.
public struct AgentReviewQueue: Equatable {
    public let groups: [AgentReviewGroup]

    public init(
        sources: [AgentReviewSource], marks: AgentReviewMarks,
        filter: AgentReviewFilter = AgentReviewFilter(), search: String = ""
    ) {
        groups = sources.map { source in
            let all = source.report?.files ?? []
            let allowed = all.filter(filter.shows)
            let files = allowed
                .filter { AgentReviewFilter.matches($0, search: search) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                .map { AgentReviewFile(file: $0, isReviewed: marks.isReviewed($0, in: source.chatID)) }
            return AgentReviewGroup(
                chatID: source.chatID, title: source.title, directory: source.directory,
                status: Self.status(of: source), files: files,
                hiddenCount: Self.status(of: source) == .current ? all.count - allowed.count : 0
            )
        }
    }

    /// Chats worth a row: files to show, or a reason there is no answer to count.
    public var visibleGroups: [AgentReviewGroup] {
        groups.filter { !$0.files.isEmpty || ($0.status != .current && $0.status != .notRepository) }
    }

    public var pendingFileCount: Int { groups.reduce(0) { $0 + $1.pendingCount } }
    public var pendingStats: AgentChangeStats {
        AgentChangeStats(files: groups.filter { $0.status == .current }.flatMap { $0.pendingFiles.map(\.file) })
    }
    public var hiddenFileCount: Int { groups.reduce(0) { $0 + $1.hiddenCount } }
    public var pendingChatCount: Int { groups.filter { $0.pendingCount > 0 }.count }
    /// Chats whose count is missing, so the total may be short.
    public var unansweredChatCount: Int { groups.filter { $0.status == .unreachable || $0.status == .unknown }.count }

    private static func status(of source: AgentReviewSource) -> AgentReviewGroup.Status {
        guard source.isReachable else { return .unreachable }
        guard let report = source.report else { return source.isLoading ? .checking : .unknown }
        return report.isRepository ? .current : .notRepository
    }
}
