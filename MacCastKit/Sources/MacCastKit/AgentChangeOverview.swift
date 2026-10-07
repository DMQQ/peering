import Foundation
import RemoteCore

/// Everything the Changes screen draws, worked out once per new answer rather than on every redraw.
public struct AgentChangeOverview: Equatable {
    public let entries: [AgentChangeEntry]
    public let tree: AgentChangeTree
    public let added: Int
    public let removed: Int
    public let message: String?
    public let isTruncated: Bool
    /// Changed files the filter took out, before the search narrowed anything: they are not in ``entries``.
    public let hiddenCount: Int

    /// Only what the filter and the search show is counted, listed or put in the tree.
    public init(
        report: AgentChangesReport?, edits: [AgentFileEdit],
        filter: AgentReviewFilter = AgentReviewFilter(), search: String = ""
    ) {
        let all = AgentChangeSet.entries(report: report, edits: edits)
        let allowed = all.filter(filter.shows)
        hiddenCount = all.count - allowed.count
        entries = allowed.filter { AgentReviewFilter.matches(path: $0.path, search: search) }
        let changedPaths = Set(all.map(\.path))
        let unchanged = (report?.paths ?? []).filter {
            !changedPaths.contains($0) && filter.showsUnchanged(path: $0) && AgentReviewFilter.matches(path: $0, search: search)
        }
        tree = AgentChangeTree(paths: unchanged, changed: Set(entries.map(\.path)))
        added = entries.reduce(0) { $0 + $1.added }
        removed = entries.reduce(0) { $0 + $1.removed }
        message = report?.message
        isTruncated = report?.truncated ?? false
    }

    public func entry(at path: String) -> AgentChangeEntry? {
        entries.first { $0.path == path }
    }
}
