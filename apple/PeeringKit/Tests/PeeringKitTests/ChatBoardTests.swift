import Foundation
import RemoteCore
import Testing

@testable import PeeringKit

@Suite("Chat board")
struct ChatBoardTests {
    private func entry(
        _ state: AgentSessionState,
        at seconds: TimeInterval,
        isPaused: Bool = false,
        isUnread: Bool = false
    ) -> ChatBoardEntry {
        ChatBoardEntry(
            id: UUID(),
            macSessionID: UUID(),
            macName: "Studio",
            agentID: "claude",
            title: "Chat",
            snippet: nil,
            state: state,
            isPaused: isPaused,
            changedAt: Date(timeIntervalSince1970: seconds),
            isUnread: isUnread
        )
    }

    @Test("needs you comes first, then working, then done")
    func groupOrder() {
        let board = ChatBoard([entry(.idle, at: 30), entry(.working, at: 20), entry(.awaitingApproval, at: 10)])

        #expect(board.sections.map(\.group) == [.needsYou, .working, .done])
    }

    @Test("a group with no chats is left out")
    func emptyGroupsOmitted() {
        let board = ChatBoard([entry(.working, at: 1)])

        #expect(board.sections.map(\.group) == [.working])
    }

    @Test("within a group the newest change is first")
    func newestFirst() {
        let older = entry(.idle, at: 10)
        let newer = entry(.exited, at: 20)
        let board = ChatBoard([older, newer])

        #expect(board.sections.first?.entries.map(\.id) == [newer.id, older.id])
    }

    @Test("a paused chat is done even if its last state was working")
    func pausedIsDone() {
        #expect(entry(.working, at: 1, isPaused: true).group == .done)
    }

    @Test("failed and ended chats are done")
    func endedIsDone() {
        #expect(entry(.failed, at: 1).group == .done)
        #expect(entry(.exited, at: 1).group == .done)
    }

    @Test("counts per group and unread")
    func counts() {
        let board = ChatBoard([
            entry(.awaitingApproval, at: 1),
            entry(.awaitingApproval, at: 2),
            entry(.idle, at: 3, isUnread: true),
        ])

        #expect(board.count == 3)
        #expect(board.count(of: .needsYou) == 2)
        #expect(board.count(of: .working) == 0)
        #expect(board.unreadCount == 1)
    }
}

@Suite("Chat change clock")
struct ChatChangeClockTests {
    private let id = UUID()
    private let began = Date(timeIntervalSince1970: 100)
    private let firstSight = Date(timeIntervalSince1970: 1_000)
    private let later = Date(timeIntervalSince1970: 2_000)
    private let latest = Date(timeIntervalSince1970: 3_000)

    @Test("a chat only seen once keeps its fallback date and is not unread")
    func firstSightIsNotAChange() {
        var clock = ChatChangeClock()
        clock.observe(id, fingerprint: "idle", at: firstSight)

        #expect(clock.changedAt(id, fallback: began) == began)
        #expect(clock.isUnread(id) == false)
    }

    @Test("a different fingerprint is dated and unread")
    func changeIsDated() {
        var clock = ChatChangeClock()
        clock.observe(id, fingerprint: "working", at: firstSight)
        clock.observe(id, fingerprint: "idle", at: later)

        #expect(clock.changedAt(id, fallback: began) == later)
        #expect(clock.isUnread(id))
    }

    @Test("the same fingerprint again does not move the date")
    func sameFingerprintKeepsDate() {
        var clock = ChatChangeClock()
        clock.observe(id, fingerprint: "working", at: firstSight)
        clock.observe(id, fingerprint: "idle", at: later)
        clock.observe(id, fingerprint: "idle", at: latest)

        #expect(clock.changedAt(id, fallback: began) == later)
    }

    @Test("looking at a chat clears unread until it changes again")
    func seenClearsUnread() {
        var clock = ChatChangeClock()
        clock.observe(id, fingerprint: "working", at: firstSight)
        clock.observe(id, fingerprint: "idle", at: later)
        clock.markSeen(id, at: later)

        #expect(clock.isUnread(id) == false)

        clock.observe(id, fingerprint: "working", at: latest)

        #expect(clock.isUnread(id))
    }
}
