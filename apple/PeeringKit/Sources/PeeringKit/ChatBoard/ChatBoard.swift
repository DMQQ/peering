import Foundation

/// The board's order: Needs you, then Working, then Done, each newest change first.
public struct ChatBoard: Equatable, Sendable {
    public struct Section: Equatable, Sendable, Identifiable {
        public let group: ChatBoardGroup
        public let entries: [ChatBoardEntry]
        public var id: ChatBoardGroup { group }
    }

    public let sections: [Section]

    public init(_ entries: [ChatBoardEntry]) {
        let grouped = Dictionary(grouping: entries, by: \.group)
        sections = ChatBoardGroup.allCases.compactMap { group in
            guard let members = grouped[group], !members.isEmpty else { return nil }
            return Section(group: group, entries: members.sorted(by: Self.newerFirst))
        }
    }

    public var isEmpty: Bool { sections.isEmpty }

    public var count: Int { sections.reduce(0) { $0 + $1.entries.count } }

    public func count(of group: ChatBoardGroup) -> Int {
        sections.first { $0.group == group }?.entries.count ?? 0
    }

    public var unreadCount: Int {
        sections.reduce(0) { $0 + $1.entries.filter(\.isUnread).count }
    }

    /// Ties broken by ID so a redraw never swaps two rows changed in the same instant.
    private static func newerFirst(_ lhs: ChatBoardEntry, _ rhs: ChatBoardEntry) -> Bool {
        if lhs.changedAt != rhs.changedAt { return lhs.changedAt > rhs.changedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
