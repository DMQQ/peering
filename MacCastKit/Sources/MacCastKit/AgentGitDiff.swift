import Foundation
import RemoteCore

/// Reads the patch `git diff` prints into one entry per file, and gives an untracked file the same shape.
public enum AgentGitDiff {
    public static let truncationNote = "… (the rest of this file's diff is not shown)"

    /// - Parameter perFileLimit: bytes of diff kept for one file; counts still cover the whole file.
    public static func files(in patch: String, perFileLimit: Int = 200 * 1024) -> [AgentChangedFile] {
        var blocks: [[Substring]] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                blocks.append([line])
            } else if !blocks.isEmpty {
                blocks[blocks.count - 1].append(line)
            }
        }
        return blocks.compactMap { file(from: $0, limit: perFileLimit) }
    }

    /// A file git does not track yet, as an all-added diff. Binary content has no diff.
    public static func untracked(path: String, content: String?, limit: Int = 200 * 1024) -> AgentChangedFile {
        guard let content else {
            return AgentChangedFile(path: path, kind: .untracked, added: 0, removed: 0, diff: nil)
        }
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        var text = "--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1,\(lines.count) @@\n"
        text += lines.map { "+" + $0 }.joined(separator: "\n")
        return AgentChangedFile(path: path, kind: .untracked, added: lines.count, removed: 0, diff: clipped(text, to: limit))
    }

    private static func file(from block: [Substring], limit: Int) -> AgentChangedFile? {
        guard let header = block.first, let path = path(header: header, block: block) else { return nil }
        let isBinary = block.contains { $0.hasPrefix("Binary files ") || $0.hasPrefix("GIT binary patch") }
        let kind: AgentChangeKind
        if block.contains(where: { $0.hasPrefix("new file mode") }) {
            kind = .added
        } else if block.contains(where: { $0.hasPrefix("deleted file mode") }) {
            kind = .deleted
        } else {
            kind = .modified
        }
        guard !isBinary, let firstHunk = block.firstIndex(where: { $0.hasPrefix("@@") }) else {
            return AgentChangedFile(path: path, kind: kind, added: 0, removed: 0, diff: nil)
        }
        let body = block[firstHunk...]
        let added = body.filter { $0.hasPrefix("+") }.count
        let removed = body.filter { $0.hasPrefix("-") }.count
        var text = block.joined(separator: "\n")
        if text.hasSuffix("\n") { text.removeLast() }
        return AgentChangedFile(path: path, kind: kind, added: added, removed: removed, diff: clipped(text, to: limit))
    }

    /// Taken from the `---`/`+++` lines where there are any, since a name with a space makes the `diff --git` line ambiguous; a binary file has neither, and its two names are equal because renames are off.
    private static func path(header: Substring, block: [Substring]) -> String? {
        for prefix in ["+++ b/", "--- a/"] {
            if let line = block.first(where: { $0.hasPrefix(prefix) }) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\t"))
            }
        }
        let rest = header.dropFirst("diff --git a/".count)
        let length = (rest.count - 3) / 2
        guard length > 0, rest.count == 2 * length + 3 else { return nil }
        return String(rest.prefix(length))
    }

    private static func clipped(_ text: String, to limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var kept = ""
        var size = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            size += line.utf8.count + 1
            if size > limit { break }
            kept += line + "\n"
        }
        return kept + truncationNote
    }
}
