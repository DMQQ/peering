import Foundation
import RemoteCore

/// What was sent, read back out of the prompt: the leading `@/path` mentions are the files, the rest is the message.
public enum AgentMentions {
    public static func split(_ text: String) -> (files: [String], rest: String) {
        var files: [String] = []
        var remaining = Substring(text)
        while remaining.hasPrefix("@/") {
            let end = remaining.firstIndex(of: " ") ?? remaining.endIndex
            files.append(String(remaining[remaining.index(after: remaining.startIndex)..<end]))
            remaining = remaining[end...].drop { $0 == " " }
        }
        return (files, String(remaining))
    }
}

/// The `@path` being typed at the end of a message: the folder it points into and the start of the name inside it.
public struct MentionQuery: Equatable {
    /// What follows the `@`, as typed.
    public let typed: String
    /// The part up to and including the last slash, relative to the project (or absolute).
    public let folderPart: String
    public let namePart: String

    /// The last word of the draft, when it starts with `@`. The caret is not known to a SwiftUI field, so this is the end of the text: where a mention is nearly always being typed.
    public init?(draft: String) {
        guard let range = draft.range(of: "@[^\\s@]*$", options: .regularExpression),
              range.lowerBound == draft.startIndex || draft[draft.index(before: range.lowerBound)].isWhitespace
        else { return nil }
        let typed = String(draft[range].dropFirst())
        self.typed = typed
        if let slash = typed.lastIndex(of: "/") {
            folderPart = String(typed[...slash])
            namePart = String(typed[typed.index(after: slash)...])
        } else {
            folderPart = ""
            namePart = typed
        }
    }

    /// The folder to list, on the Mac.
    public func folder(in project: String) -> String {
        let base = folderPart.hasPrefix("/") ? folderPart : (project.hasSuffix("/") ? project : project + "/") + folderPart
        let trimmed = base.count > 1 && base.hasSuffix("/") ? String(base.dropLast()) : base
        return (trimmed as NSString).standardizingPath
    }

    /// What the folder holds that fits what has been typed: names starting with it first, then folders, then the rest.
    public func matches(in entries: [RemoteDirectoryEntry]?) -> [RemoteDirectoryEntry] {
        guard let entries else { return [] }
        let showsHidden = namePart.hasPrefix(".")
        let lowered = namePart.lowercased()
        return entries
            .filter { showsHidden || !$0.name.hasPrefix(".") }
            .filter { namePart.isEmpty || $0.name.localizedStandardContains(namePart) }
            .sorted { lhs, rhs in
                let leftStarts = lhs.name.lowercased().hasPrefix(lowered)
                let rightStarts = rhs.name.lowercased().hasPrefix(lowered)
                if leftStarts != rightStarts { return leftStarts }
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    public func replacing(in draft: String, with path: String, isFolder: Bool) -> String {
        guard let range = draft.range(of: "@[^\\s@]*$", options: .regularExpression) else { return draft }
        let escaped = path.contains(" ") ? path.replacingOccurrences(of: " ", with: "\\ ") : path
        return draft.replacingCharacters(in: range, with: "@" + escaped + (isFolder ? "/" : " "))
    }
}
