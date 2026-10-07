import Foundation
import RemoteCore

/// Which files the reader has marked reviewed, per chat, each tied to the fingerprint it had when marked.
public struct AgentReviewMarks: Codable, Equatable {
    /// Chat id string, then path, then the fingerprint at the time of the mark.
    private var marks: [String: [String: String]] = [:]

    public init() {}

    public func isReviewed(_ file: AgentChangedFile, in chat: UUID) -> Bool {
        marks[chat.uuidString]?[file.path] == AgentReviewFingerprint.of(file)
    }

    public mutating func setReviewed(_ reviewed: Bool, _ file: AgentChangedFile, in chat: UUID) {
        let key = chat.uuidString
        if reviewed {
            marks[key, default: [:]][file.path] = AgentReviewFingerprint.of(file)
        } else {
            marks[key]?[file.path] = nil
            if marks[key]?.isEmpty == true { marks[key] = nil }
        }
    }

    /// Forgets marks a newer answer has outdated: a file that changed again or left the list. Only a real answer prunes, so a failed or empty one cannot wipe the marks.
    public mutating func prune(chat: UUID, against report: AgentChangesReport) {
        guard report.isRepository, var kept = marks[chat.uuidString] else { return }
        let current = Dictionary(report.files.map { ($0.path, AgentReviewFingerprint.of($0)) }, uniquingKeysWith: { first, _ in first })
        kept = kept.filter { current[$0.key] == $0.value }
        marks[chat.uuidString] = kept.isEmpty ? nil : kept
    }

    /// Drops every mark of a chat that no longer exists.
    public mutating func retain(chats: Set<UUID>) {
        let live = Set(chats.map(\.uuidString))
        marks = marks.filter { live.contains($0.key) }
    }
}
