import Foundation
import Testing

@testable import PeeringKit

struct AgentQueueStoreTests {
    private func freshDefaults() -> UserDefaults {
        let name = "AgentQueueStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aQueueComesBackInTheOrderItWasTyped() {
        let defaults = freshDefaults()
        let chat = UUID()
        AgentQueueStore.save([chat: AgentPromptQueue(prompts: ["a", "b", "c"])], hostKey: "mac", defaults: defaults)
        #expect(AgentQueueStore.load(hostKey: "mac", defaults: defaults)[chat]?.prompts == ["a", "b", "c"])
    }

    @Test func eachMacKeepsItsOwnQueues() {
        let defaults = freshDefaults()
        let chat = UUID()
        AgentQueueStore.save([chat: AgentPromptQueue(prompts: ["a"])], hostKey: "one", defaults: defaults)
        #expect(AgentQueueStore.load(hostKey: "two", defaults: defaults).isEmpty)
    }

    @Test func savingAnEmptyQueueForgetsIt() {
        let defaults = freshDefaults()
        let chat = UUID()
        AgentQueueStore.save([chat: AgentPromptQueue(prompts: ["a"])], hostKey: "mac", defaults: defaults)
        AgentQueueStore.save([chat: AgentPromptQueue()], hostKey: "mac", defaults: defaults)
        #expect(AgentQueueStore.load(hostKey: "mac", defaults: defaults).isEmpty)
    }
}
