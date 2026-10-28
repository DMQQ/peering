import Testing

@testable import PeeringKit

struct AgentPromptQueueTests {
    @Test func idleChatSendsAtOnce() {
        var queue = AgentPromptQueue()
        #expect(queue.submit("a", sessionState: .idle) == .send)
        #expect(queue.prompts.isEmpty)
    }

    @Test func unknownChatSendsAtOnce() {
        var queue = AgentPromptQueue()
        #expect(queue.submit("a", sessionState: nil) == .send)
    }

    @Test func runningTurnQueuesIncludingWhileWaitingOnApproval() {
        var queue = AgentPromptQueue()
        #expect(queue.submit("a", sessionState: .working) == .queued)
        #expect(queue.submit("b", sessionState: .awaitingApproval) == .queued)
        #expect(queue.prompts == ["a", "b"])
    }

    @Test func waitingMessagesKeepTheOrderEvenOnceTheChatIsIdle() {
        var queue = AgentPromptQueue()
        _ = queue.submit("a", sessionState: .working)
        #expect(queue.submit("b", sessionState: .idle) == .queued)
        #expect(queue.prompts == ["a", "b"])
    }

    @Test func turnEndReleasesOneAtATime() {
        var queue = AgentPromptQueue()
        _ = queue.submit("a", sessionState: .working)
        _ = queue.submit("b", sessionState: .working)
        #expect(queue.release(state: .working) == .hold)
        #expect(queue.release(state: .idle) == .send("a"))
        #expect(queue.prompts == ["b"])
        #expect(queue.release(state: .idle) == .send("b"))
        #expect(queue.release(state: .idle) == .hold)
    }

    @Test func aChatThatDiedDropsWhatWaitedForIt() {
        var queue = AgentPromptQueue()
        _ = queue.submit("a", sessionState: .working)
        #expect(queue.release(state: .failed) == .dropped)
        #expect(queue.prompts.isEmpty)
        _ = queue.submit("b", sessionState: .working)
        #expect(queue.release(state: .exited) == .dropped)
    }

    @Test func removeIgnoresAnOffsetThatIsNotThere() {
        var queue = AgentPromptQueue()
        _ = queue.submit("a", sessionState: .working)
        _ = queue.submit("b", sessionState: .working)
        queue.remove(at: 5)
        queue.remove(at: -1)
        #expect(queue.prompts == ["a", "b"])
        queue.remove(at: 0)
        #expect(queue.prompts == ["b"])
    }
}

struct AgentPromptQueueRemovalTests {
    @Test func removesTheMessageAtTheOffsetWhenItIsStillThere() {
        var queue = AgentPromptQueue(prompts: ["a", "b", "c"])
        let removed = queue.remove("b", at: 1)
        #expect(removed)
        #expect(queue.prompts == ["a", "c"])
    }

    @Test func aShiftedQueueRemovesTheSameTextNotTheNeighbour() {
        var queue = AgentPromptQueue(prompts: ["b", "c"])
        let removed = queue.remove("b", at: 1)
        #expect(removed)
        #expect(queue.prompts == ["c"])
    }

    @Test func aMessageAlreadySentRemovesNothing() {
        var queue = AgentPromptQueue(prompts: ["c"])
        let removed = queue.remove("a", at: 0)
        #expect(removed == false)
        #expect(queue.prompts == ["c"])
    }
}
