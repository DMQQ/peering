import Foundation
import RemoteCore
import Testing

@testable import MacCastKit

private func file(_ path: String, diff: String = "+a", added: Int = 1, kind: AgentChangeKind = .modified) -> AgentChangedFile {
    AgentChangedFile(path: path, kind: kind, added: added, removed: 0, diff: diff)
}

private func report(_ files: [AgentChangedFile], isRepository: Bool = true) -> AgentChangesReport {
    AgentChangesReport(isRepository: isRepository, files: files, paths: [], truncated: false)
}

private func source(_ chat: UUID, _ report: AgentChangesReport?, reachable: Bool = true, loading: Bool = false) -> AgentReviewSource {
    AgentReviewSource(chatID: chat, title: "Chat", directory: "/p", report: report, isReachable: reachable, isLoading: loading)
}

struct AgentReviewMarksTests {
    @Test func aMarkHoldsWhileTheDiffIsUnchanged() {
        let chat = UUID()
        var marks = AgentReviewMarks()
        marks.setReviewed(true, file("a.swift"), in: chat)
        #expect(marks.isReviewed(file("a.swift"), in: chat))
        #expect(!marks.isReviewed(file("a.swift"), in: UUID()))
    }

    @Test func aChangedDiffResetsTheMark() {
        let chat = UUID()
        var marks = AgentReviewMarks()
        marks.setReviewed(true, file("a.swift", diff: "+a"), in: chat)
        #expect(!marks.isReviewed(file("a.swift", diff: "+b"), in: chat))
    }

    @Test func unmarkingClearsIt() {
        let chat = UUID()
        var marks = AgentReviewMarks()
        marks.setReviewed(true, file("a"), in: chat)
        marks.setReviewed(false, file("a"), in: chat)
        #expect(!marks.isReviewed(file("a"), in: chat))
        #expect(marks == AgentReviewMarks())
    }

    @Test func pruningDropsOutdatedMarksButKeepsCurrentOnes() {
        let chat = UUID()
        var marks = AgentReviewMarks()
        marks.setReviewed(true, file("keep"), in: chat)
        marks.setReviewed(true, file("moved", diff: "+x"), in: chat)
        marks.setReviewed(true, file("gone"), in: chat)
        marks.prune(chat: chat, against: report([file("keep"), file("moved", diff: "+y")]))
        #expect(marks.isReviewed(file("keep"), in: chat))
        #expect(!marks.isReviewed(file("moved", diff: "+x"), in: chat))
        #expect(!marks.isReviewed(file("gone"), in: chat))
    }

    @Test func aFailedAnswerDoesNotPrune() {
        let chat = UUID()
        var marks = AgentReviewMarks()
        marks.setReviewed(true, file("a"), in: chat)
        marks.prune(chat: chat, against: .failure("offline"))
        #expect(marks.isReviewed(file("a"), in: chat))
    }

    @Test func closedChatsLoseTheirMarks() {
        let open = UUID()
        let closed = UUID()
        var marks = AgentReviewMarks()
        marks.setReviewed(true, file("a"), in: open)
        marks.setReviewed(true, file("a"), in: closed)
        marks.retain(chats: [open])
        #expect(marks.isReviewed(file("a"), in: open))
        #expect(!marks.isReviewed(file("a"), in: closed))
    }

    @Test func marksSurviveEncoding() throws {
        let chat = UUID()
        var marks = AgentReviewMarks()
        marks.setReviewed(true, file("a"), in: chat)
        let decoded = try JSONDecoder().decode(AgentReviewMarks.self, from: JSONEncoder().encode(marks))
        #expect(decoded.isReviewed(file("a"), in: chat))
    }

    @Test func fingerprintIsStableAcrossCalls() {
        #expect(AgentReviewFingerprint.of(file("a")) == AgentReviewFingerprint.of(file("a")))
        #expect(AgentReviewFingerprint.of(file("a", kind: .added)) != AgentReviewFingerprint.of(file("a", kind: .modified)))
    }
}

struct AgentReviewQueueTests {
    @Test func countsPendingFilesAndChatsAndSkipsReviewedOnes() {
        let first = UUID()
        let second = UUID()
        var marks = AgentReviewMarks()
        marks.setReviewed(true, file("b"), in: first)
        let queue = AgentReviewQueue(
            sources: [source(first, report([file("a"), file("b")])), source(second, report([file("c")])), source(UUID(), report([]))],
            marks: marks
        )
        #expect(queue.pendingFileCount == 2)
        #expect(queue.pendingChatCount == 2)
        #expect(queue.visibleGroups.count == 2)
        #expect(queue.groups[0].files.map(\.isReviewed) == [false, true])
    }

    @Test func anUnreachableMacIsNotCountedAsFact() {
        let queue = AgentReviewQueue(sources: [source(UUID(), report([file("a")]), reachable: false)], marks: AgentReviewMarks())
        #expect(queue.pendingFileCount == 0)
        #expect(queue.unansweredChatCount == 1)
        #expect(queue.visibleGroups.first?.status == .unreachable)
    }

    @Test func aChatNotYetAnsweredIsUnknownOrChecking() {
        let queue = AgentReviewQueue(
            sources: [source(UUID(), nil), source(UUID(), nil, loading: true)], marks: AgentReviewMarks()
        )
        #expect(queue.groups.map(\.status) == [.unknown, .checking])
        #expect(queue.unansweredChatCount == 1)
    }

    @Test func aFolderOutsideGitIsLeftOut() {
        let queue = AgentReviewQueue(sources: [source(UUID(), report([], isRepository: false))], marks: AgentReviewMarks())
        #expect(queue.visibleGroups.isEmpty)
        #expect(queue.pendingFileCount == 0)
    }

    @Test func filesAreOrderedByPath() {
        let queue = AgentReviewQueue(sources: [source(UUID(), report([file("b10"), file("b2")]))], marks: AgentReviewMarks())
        #expect(queue.groups[0].files.map(\.id) == ["b2", "b10"])
    }
}

struct AgentReviewRefreshPolicyTests {
    @Test func aChatIsAskedOnceInsideTheInterval() {
        var policy = AgentReviewRefreshPolicy()
        let chat = UUID()
        let start = ContinuousClock.Instant.now
        #expect(policy.chatsToAsk([chat], reason: .hubAppeared, now: start) == [chat])
        #expect(policy.chatsToAsk([chat], reason: .hubAppeared, now: start + .seconds(10)).isEmpty)
        #expect(policy.chatsToAsk([chat], reason: .hubAppeared, now: start + .seconds(31)) == [chat])
    }

    @Test func aFinishedTurnAsksSoonerButNotInABurst() {
        var policy = AgentReviewRefreshPolicy()
        let chat = UUID()
        let start = ContinuousClock.Instant.now
        _ = policy.chatsToAsk([chat], reason: .hubAppeared, now: start)
        #expect(policy.chatsToAsk([chat], reason: .turnFinished, now: start + .seconds(1)).isEmpty)
        #expect(policy.chatsToAsk([chat], reason: .turnFinished, now: start + .seconds(5)) == [chat])
    }
}

struct AgentReviewSendPlanTests {
    @Test func eachChatGetsItsOwnCommentsAndEmptyChatsAreSkipped() {
        let first = UUID()
        let second = UUID()
        let plan = AgentReviewSendPlan(chats: [
            (first, "Auth", [AgentReviewComment(path: "a.swift", line: 3, text: "rename")]),
            (second, "Empty", []),
            (UUID(), "Docs", [AgentReviewComment(path: "b.md", text: "one"), AgentReviewComment(path: "c.md", text: "two")]),
        ])
        #expect(plan.items.count == 2)
        #expect(plan.commentCount == 3)
        #expect(plan.items[0].chatID == first)
        #expect(plan.items[0].prompt.contains("a.swift:3"))
        #expect(!plan.items[0].prompt.contains("b.md"))
    }
}
