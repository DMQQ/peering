import Foundation
import RemoteCore
import Testing

@testable import PeeringKit

@Suite("Agent guard store")
struct AgentGuardStoreTests {
    private func store() -> AgentGuardStore {
        let name = "AgentGuardStoreTests.\(UUID().uuidString)"
        return AgentGuardStore(defaults: UserDefaults(suiteName: name) ?? .standard)
    }

    @Test("a cap is kept per chat and an empty one removes it")
    func caps() throws {
        let store = store()
        let id = UUID()
        try store.setCap(AgentSpendingCap(costUSD: 3), for: id)
        #expect(store.cap(for: id) == AgentSpendingCap(costUSD: 3))
        try store.setCap(AgentSpendingCap(), for: id)
        #expect(store.cap(for: id) == nil)
    }

    @Test("caps of chats the Mac no longer lists are dropped")
    func pruning() throws {
        let store = store()
        let kept = UUID(), gone = UUID()
        try store.setCap(AgentSpendingCap(contextPercent: 50), for: kept)
        try store.setCap(AgentSpendingCap(contextPercent: 60), for: gone)
        try store.keepCaps(only: [kept])
        #expect(store.caps().keys.sorted { $0.uuidString < $1.uuidString } == [kept])
    }

    @Test("given warnings survive a new store over the same defaults")
    func warnings() {
        let defaults = UserDefaults(suiteName: "AgentGuardStoreTests.\(UUID().uuidString)") ?? .standard
        AgentGuardStore(defaults: defaults).givenWarnings = ["1-80"]
        #expect(AgentGuardStore(defaults: defaults).givenWarnings == ["1-80"])
    }
}
