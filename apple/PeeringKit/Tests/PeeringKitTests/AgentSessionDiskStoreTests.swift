import Foundation
import RemoteCore
import Testing

@testable import PeeringKit

@Suite struct AgentSessionDiskStoreTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("agent-store-\(UUID().uuidString)")
    }

    private func record(_ id: UUID = UUID()) -> AgentSessionRecord {
        AgentSessionRecord(
            id: id, ownerClientID: "phone", agentID: "claude", title: "Claude Code · app", directory: "/tmp/app",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), cliSessionID: "abc", model: "sonnet",
            permissionMode: .acceptEdits, usage: AgentUsage(inputTokens: 3),
            events: [AgentStreamEvent(index: 1, payload: .userPrompt(text: "hi"))], nextIndex: 2, truncatedAtFront: false
        )
    }

    @Test func aSavedRecordComesBackEqual() throws {
        let store = AgentSessionDiskStore(directory: scratch())
        let saved = record()
        try store.save(saved)
        #expect(store.loadAll() == [saved])
    }

    @Test func savingAgainReplacesTheFile() throws {
        let store = AgentSessionDiskStore(directory: scratch())
        var saved = record()
        try store.save(saved)
        saved.title = "Renamed"
        try store.save(saved)
        #expect(store.loadAll().map(\.title) == ["Renamed"])
    }

    @Test func removeDeletesOnlyThatChat() throws {
        let store = AgentSessionDiskStore(directory: scratch())
        let keep = record()
        let drop = record()
        try store.save(keep)
        try store.save(drop)
        store.remove(drop.id)
        #expect(store.loadAll().map(\.id) == [keep.id])
    }

    @Test func anUnreadableFileIsSkippedAndTheRestLoad() throws {
        let directory = scratch()
        let store = AgentSessionDiskStore(directory: directory)
        let good = record()
        try store.save(good)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))
        #expect(store.loadAll().map(\.id) == [good.id])
    }

    @Test func aMissingFolderLoadsNothing() {
        #expect(AgentSessionDiskStore(directory: scratch()).loadAll().isEmpty)
    }
}
