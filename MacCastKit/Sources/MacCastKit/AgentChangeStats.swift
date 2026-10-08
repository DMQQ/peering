import Foundation
import RemoteCore

/// The git-style totals over a set of changed files: how many, and how many lines went in and out.
public struct AgentChangeStats: Equatable, Sendable {
    public let fileCount: Int
    public let added: Int
    public let removed: Int

    public static let empty = AgentChangeStats(files: [])

    /// A file with no diff and no counts (binary, or too large to read) is a file but adds no lines to either total.
    public init(files: [AgentChangedFile]) {
        fileCount = files.count
        let known = files.filter { $0.diff != nil || $0.added != 0 || $0.removed != 0 }
        added = known.reduce(0) { $0 + max($1.added, 0) }
        removed = known.reduce(0) { $0 + max($1.removed, 0) }
    }

    public func addedText(locale: Locale = .current) -> String { "+" + Self.grouped(added, locale: locale) }
    public func removedText(locale: Locale = .current) -> String { "-" + Self.grouped(removed, locale: locale) }

    public static func grouped(_ value: Int, locale: Locale = .current) -> String {
        value.formatted(.number.grouping(.automatic).locale(locale))
    }
}
