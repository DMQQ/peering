import Foundation
import MacCastKit
import RemoteCore

/// The conversations Claude Code keeps under `~/.claude/projects`, started in a terminal or here.
enum ClaudeSessionLibrary {
    private static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    private static let windowBytes = 64 * 1024
    /// A file is megabytes; the last of it is the recent conversation, and the buffer that holds it keeps no more than that anyway.
    private static let conversationBytes = 8 * 1024 * 1024
    private static let maximumAge: TimeInterval = 60 * 24 * 3600
    private static let openElsewhereWindow: TimeInterval = 120

    /// Newest first. Chats this app already holds are left out: they live in the same folder and would list twice.
    static func list(excluding known: Set<String>, limit: Int = 30, now: Date = Date()) -> [AgentResumableSession] {
        var found: [AgentResumableSession] = []
        for file in files().sorted(by: { $0.modified > $1.modified }) {
            guard found.count < limit, now.timeIntervalSince(file.modified) < maximumAge else { break }
            guard !known.contains(file.id),
                  let summary = summary(of: file.url),
                  !FolderAccessWatch.isMissing(summary.directory)
            else { continue }
            found.append(AgentResumableSession(
                agentID: ClaudeCodeAdapter.command,
                cliSessionID: file.id,
                directory: summary.directory,
                title: summary.title,
                modifiedAt: file.modified,
                mayBeOpenElsewhere: now.timeIntervalSince(file.modified) < openElsewhereWindow
            ))
        }
        return found
    }

    struct Conversation {
        let summary: AgentClaudeSessionFile.Summary
        let events: [AgentStreamEvent.Payload]
        let usage: AgentUsage?
        let startsMidConversation: Bool
    }

    static func conversation(cliSessionID: String) -> Conversation? {
        guard let file = files().first(where: { $0.id == cliSessionID }),
              let summary = summary(of: file.url),
              let handle = try? FileHandle(forReadingFrom: file.url)
        else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(conversationBytes) ? size - UInt64(conversationBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return Conversation(
            summary: summary,
            events: AgentClaudeSessionFile.events(from: text),
            usage: AgentClaudeSessionFile.usage(from: text),
            startsMidConversation: start > 0
        )
    }

    private struct SessionFile {
        let id: String
        let url: URL
        let modified: Date
    }

    private static func files() -> [SessionFile] {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.flatMap { folder -> [SessionFile] in
            let urls = (try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            return urls.compactMap { url in
                guard url.pathExtension == "jsonl",
                      let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { return nil }
                return SessionFile(id: url.deletingPathExtension().lastPathComponent, url: url, modified: modified)
            }
        }
    }

    private static func summary(of url: URL) -> AgentClaudeSessionFile.Summary? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: windowBytes)) ?? Data()
        var tail = Data()
        if size > UInt64(windowBytes) {
            try? handle.seek(toOffset: size - UInt64(windowBytes))
            tail = (try? handle.read(upToCount: windowBytes)) ?? Data()
        }
        return AgentClaudeSessionFile.summary(
            head: String(decoding: head, as: UTF8.self), tail: String(decoding: tail, as: UTF8.self)
        )
    }
}
