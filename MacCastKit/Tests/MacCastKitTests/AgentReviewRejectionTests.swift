import Foundation
import RemoteCore
import Testing

@testable import MacCastKit

private func comment(_ path: String, _ text: String = "fix this") -> AgentReviewComment {
    AgentReviewComment(path: path, line: 3, text: text)
}

private func target(_ chat: UUID, _ path: String) -> AgentReviewTarget { AgentReviewTarget(chatID: chat, path: path) }

struct AgentReviewRejectionTests {
    @Test func theReasonRidesInThePromptAndABlankOneDoesNot() {
        let chat = UUID()
        let chosen: Set = [target(chat, "a.swift")]
        let with = AgentReviewRejection(chats: [(chat, "A", [])], selection: chosen, reason: "  wrong layout  ")
        let without = AgentReviewRejection(chats: [(chat, "A", [])], selection: chosen, reason: "   ")
        #expect(with.items[0].prompt.contains("Why: wrong layout\n"))
        #expect(!without.items[0].prompt.contains("Why:"))
    }

    @Test func anEmptySelectionProducesNothing() {
        let chat = UUID()
        let rejection = AgentReviewRejection(chats: [(chat, "A", [comment("a")])], selection: [])
        #expect(rejection.items.isEmpty)
        #expect(rejection.fileCount == 0)
    }

    @Test func eachChatGetsOnePromptWithOnlyItsFiles() {
        let first = UUID(), second = UUID()
        let rejection = AgentReviewRejection(
            chats: [(first, "One", []), (second, "Two", []), (UUID(), "Untouched", [])],
            selection: [target(first, "b.swift"), target(first, "a.swift"), target(second, "c.swift")]
        )
        #expect(rejection.items.map(\.chatID) == [first, second])
        #expect(rejection.items[0].paths == ["a.swift", "b.swift"])
        #expect(rejection.items[1].prompt.contains("- c.swift"))
        #expect(!rejection.items[1].prompt.contains("a.swift"))
        #expect(rejection.fileCount == 3)
    }

    @Test func commentsAreIncludedOnlyForSelectedFiles() {
        let chat = UUID()
        let kept = comment("a.swift", "rename this")
        let other = comment("b.swift", "unrelated remark")
        let rejection = AgentReviewRejection(chats: [(chat, "A", [kept, other])], selection: [target(chat, "a.swift")])
        let item = rejection.items[0]
        #expect(item.commentIDs == [kept.id])
        #expect(item.prompt.contains("rename this"))
        #expect(!item.prompt.contains("unrelated remark"))
        #expect(!item.prompt.contains("b.swift"))
    }

    @Test func aFileWithoutCommentsIsAskedToBeRechecked() {
        let chat = UUID()
        let plain = AgentReviewRejection(chats: [(chat, "A", [])], selection: [target(chat, "a.swift")])
        #expect(plain.items[0].prompt.contains("rejected without a note"))
        #expect(plain.items[0].commentIDs.isEmpty)

        let commented = AgentReviewRejection(chats: [(chat, "A", [comment("a.swift")])], selection: [target(chat, "a.swift")])
        #expect(!commented.items[0].prompt.contains("rejected without a note"))

        let mixed = AgentReviewRejection(
            chats: [(chat, "A", [comment("a.swift")])], selection: [target(chat, "a.swift"), target(chat, "b.swift")]
        )
        #expect(mixed.items[0].prompt.contains("rejected without a note"))
    }

    @Test func aLongReviewStaysUnderTheHostLimit() {
        let chat = UUID()
        let comments = (0..<400).map { comment("a.swift", String(repeating: "x", count: 400) + "\($0)") }
        let paths = (0..<2000).map { "folder/with/a/long/path/file\($0).swift" }
        let rejection = AgentReviewRejection(chats: [(chat, "A", comments)], selection: Set(paths.map { target(chat, $0) }))
        let prompt = rejection.items[0].prompt
        #expect(prompt.utf8.count <= AgentReviewPrompt.maximumBytes)
        #expect(prompt.contains("more files are not listed"))
    }

    @Test func aLongCommentListStopsShortAndSaysSo() {
        let chat = UUID()
        let comments = (0..<400).map { comment("a.swift", String(repeating: "y", count: 400) + "\($0)") }
        let rejection = AgentReviewRejection(chats: [(chat, "A", comments)], selection: [target(chat, "a.swift")])
        let prompt = rejection.items[0].prompt
        #expect(prompt.utf8.count <= AgentReviewPrompt.maximumBytes)
        #expect(prompt.contains("did not fit"))
    }
}

struct AgentReviewSelectionTests {
    private func file(_ path: String) -> AgentChangedFile {
        AgentChangedFile(path: path, kind: .modified, added: 1, removed: 0, diff: "+a")
    }

    private func queue(_ chat: UUID, search: String = "", reachable: Bool = true) -> AgentReviewQueue {
        let report = AgentChangesReport(isRepository: true, files: [file("a.swift"), file("b.swift")], paths: [], truncated: false)
        let source = AgentReviewSource(chatID: chat, title: "A", directory: "/p", report: report, isReachable: reachable)
        return AgentReviewQueue(sources: [source], marks: AgentReviewMarks(), search: search)
    }

    @Test func selectableTargetsAreTheVisibleFiles() {
        let chat = UUID()
        #expect(queue(chat).selectableTargets == [target(chat, "a.swift"), target(chat, "b.swift")])
        #expect(queue(chat, search: "a.sw").selectableTargets == [target(chat, "a.swift")])
        #expect(queue(chat, reachable: false).selectableTargets.isEmpty)
    }

    @Test func aFilteredOutFileLeavesTheSelection() {
        let chat = UUID()
        let selection: Set = [target(chat, "a.swift"), target(chat, "b.swift"), target(UUID(), "gone.swift")]
        #expect(queue(chat, search: "b.sw").retaining(selection) == [target(chat, "b.swift")])
    }
}
