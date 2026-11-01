import Foundation
import RemoteCore
import Testing

@testable import PeeringKit

@Suite struct AgentSessionArchiveTests {
    private func store() -> AgentSessionDiskStore {
        AgentSessionDiskStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("agent-archive-\(UUID().uuidString)"))
    }

    private func record(cap: AgentSpendingCap? = nil) -> AgentSessionRecord {
        AgentSessionRecord(
            id: UUID(), ownerClientID: "phone", agentID: "claude", title: "Chat", directory: "/tmp/app",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), cliSessionID: "abc", model: nil,
            permissionMode: .manual, usage: nil, events: [], nextIndex: 1, truncatedAtFront: false, spendingCap: cap
        )
    }

    @Test func anArchivedChatLeavesTheActiveList() throws {
        let store = store()
        let keep = record()
        let retire = record()
        try store.save(keep)
        try store.save(retire)
        try store.archive(retire.id)
        #expect(store.loadAll().map(\.id) == [keep.id])
        #expect(store.archivedIDs() == [retire.id])
    }

    @Test func pruningDeletesOnlyArchivesPastTheLifetime() throws {
        let store = store()
        let old = record()
        let recent = record()
        try store.save(old)
        try store.save(recent)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.archive(old.id, now: now.addingTimeInterval(-91 * 24 * 3600))
        try store.archive(recent.id, now: now.addingTimeInterval(-89 * 24 * 3600))
        #expect(try store.pruneArchive(now: now) == 1)
        #expect(store.archivedIDs() == [recent.id])
    }

    @Test func pruningWithNoArchiveRemovesNothing() throws {
        #expect(try store().pruneArchive() == 0)
    }

    @Test func theSpendingCapSurvivesTheDisk() throws {
        let store = store()
        let saved = record(cap: AgentSpendingCap(costUSD: 2.5))
        try store.save(saved)
        #expect(store.loadAll().first?.spendingCap == AgentSpendingCap(costUSD: 2.5))
    }

    @Test func aRecordWrittenWithoutACapStillDecodes() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(with: encoder.encode(record(cap: AgentSpendingCap(costUSD: 1)))) as? [String: Any] ?? [:]
        object.removeValue(forKey: "spendingCap")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentSessionRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.spendingCap == nil)
    }
}
