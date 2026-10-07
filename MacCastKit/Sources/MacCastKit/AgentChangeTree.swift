import Foundation

/// A project's files as an expandable tree, with the changed ones marked.
public struct AgentChangeTree: Equatable {
    public struct Row: Equatable, Identifiable {
        /// The full relative path; a folder's ends without a slash.
        public let id: String
        public let name: String
        public let depth: Int
        public let isFolder: Bool
        /// A file: whether it changed. A folder: how many changed files lie beneath it.
        public let changedCount: Int
        public let isExpanded: Bool

        public var isChanged: Bool { changedCount > 0 }
    }

    private struct Node: Equatable {
        let name: String
        let path: String
        var children: [Int] = []
        var isFolder: Bool
        var changedCount = 0
    }

    private var nodes: [Node] = [Node(name: "", path: "", isFolder: true)]

    /// A changed path the listing lacks (a deleted file, or a folder git cannot list) is added, so nothing that changed goes unseen.
    public init(paths: [String], changed: Set<String>) {
        var index: [String: Int] = ["": 0]
        for path in Set(paths).union(changed).sorted() {
            let parts = path.split(separator: "/").map(String.init)
            var parent = 0
            var built = ""
            for (offset, part) in parts.enumerated() {
                built += (built.isEmpty ? "" : "/") + part
                let isFolder = offset < parts.count - 1
                if let existing = index[built] {
                    parent = existing
                    continue
                }
                nodes.append(Node(name: part, path: built, isFolder: isFolder))
                index[built] = nodes.count - 1
                nodes[parent].children.append(nodes.count - 1)
                parent = nodes.count - 1
            }
            if changed.contains(path) {
                var cursor: String? = path
                while let current = cursor, let at = index[current] {
                    nodes[at].changedCount += 1
                    cursor = Self.parent(of: current)
                }
                nodes[0].changedCount += 1
            }
        }
        for at in nodes.indices { sortChildren(of: at) }
    }

    /// Folders that hold a change, so the first look already shows every edited file.
    public var foldersWithChanges: Set<String> {
        Set(nodes.filter { $0.isFolder && $0.changedCount > 0 && !$0.path.isEmpty }.map(\.path))
    }

    /// Every folder, for a search that should show its matches without the reader opening each one.
    public var allFolders: Set<String> {
        Set(nodes.filter { $0.isFolder && !$0.path.isEmpty }.map(\.path))
    }

    public func rows(expanded: Set<String>) -> [Row] {
        var rows: [Row] = []
        func visit(_ at: Int, depth: Int) {
            for child in nodes[at].children {
                let node = nodes[child]
                let open = node.isFolder && expanded.contains(node.path)
                rows.append(Row(id: node.path, name: node.name, depth: depth, isFolder: node.isFolder, changedCount: node.changedCount, isExpanded: open))
                if open { visit(child, depth: depth + 1) }
            }
        }
        visit(0, depth: 0)
        return rows
    }

    private mutating func sortChildren(of at: Int) {
        let snapshot = nodes
        nodes[at].children.sort { left, right in
            let (a, b) = (snapshot[left], snapshot[right])
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private static func parent(of path: String) -> String? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        return String(path[..<slash])
    }
}
