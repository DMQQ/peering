import Foundation
import MacCastKit
import RemoteCore

/// Finds a Codex thread's session log and reads its usage. See ``AgentCodexSessionLog``.
enum CodexSessionLogFile {
    private static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)

    /// The last 512 KB is far more than the few hundred bytes the answer needs, and a long thread's
    /// log is megabytes.
    private static let tailBytes: UInt64 = 512 * 1024

    static func usage(thread: String, knownPath: inout URL?) -> AgentUsage? {
        if knownPath == nil { knownPath = find(thread: thread) }
        guard let path = knownPath, let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        return AgentCodexSessionLog.usage(fromLog: text)
    }

    /// Today's and yesterday's folders first, where a live thread's log is, then the whole tree.
    private static func find(thread: String) -> URL? {
        let calendar = Calendar.current
        let now = Date()
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayNumber = parts.day else { continue }
            let folder = root
                .appendingPathComponent(String(year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", dayNumber))
            if let match = match(thread: thread, in: folder) { return match }
        }
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.lastPathComponent.hasSuffix("\(thread).jsonl") {
            return url
        }
        return nil
    }

    private static func match(thread: String, in folder: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.first { $0.hasSuffix("\(thread).jsonl") }.map { folder.appendingPathComponent($0) }
    }
}
