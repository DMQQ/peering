import Foundation
import RemoteCore
import Testing

@testable import PeeringKit

@Suite("Agent guard store per Mac")
struct AgentGuardStoreHostTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "AgentGuardStoreHostTests.\(UUID().uuidString)") ?? .standard
    }

    @Test("pruning one Mac's caps keeps another Mac's")
    func pruneIsPerMac() throws {
        let defaults = defaults()
        let first = AgentGuardStore(defaults: defaults, hostKey: "first")
        let second = AgentGuardStore(defaults: defaults, hostKey: "second")
        let firstChat = UUID(), secondChat = UUID()
        try first.setCap(AgentSpendingCap(costUSD: 1), for: firstChat)
        try second.setCap(AgentSpendingCap(costUSD: 2), for: secondChat)
        try first.keepCaps(only: [firstChat])
        #expect(second.cap(for: secondChat) == AgentSpendingCap(costUSD: 2))
        #expect(first.cap(for: secondChat) == nil)
    }

    @Test("a Mac takes over an unkeyed cap of a chat it lists and leaves the rest")
    func unkeyedCapsMigrate() throws {
        let defaults = defaults()
        let listed = UUID(), other = UUID()
        try AgentGuardStore(defaults: defaults).setCap(AgentSpendingCap(costUSD: 3), for: listed)
        try AgentGuardStore(defaults: defaults).setCap(AgentSpendingCap(costUSD: 4), for: other)
        let mac = AgentGuardStore(defaults: defaults, hostKey: "mac")
        try mac.keepCaps(only: [listed])
        #expect(mac.cap(for: listed) == AgentSpendingCap(costUSD: 3))
        #expect(AgentGuardStore(defaults: defaults).caps() == [other: AgentSpendingCap(costUSD: 4)])
    }
}
