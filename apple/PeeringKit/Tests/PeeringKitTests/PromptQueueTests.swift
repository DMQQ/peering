import Foundation
import Testing

@testable import PeeringKit

@Suite("A queue of prompts")
struct PromptQueueTests {
    private let first = UUID()
    private let second = UUID()

    @Test func showsTheOldestFirstAndAdvancesOnAnswer() {
        var queue = PromptQueue<String>()
        queue.enqueue("a", owner: first)
        queue.enqueue("b", owner: second)
        #expect(queue.current == "a")
        #expect(queue.removeCurrent() == "a")
        #expect(queue.current == "b")
    }

    @Test func closingAnOwnerReturnsItsPromptsAndKeepsTheRest() {
        var queue = PromptQueue<String>()
        queue.enqueue("a", owner: first)
        queue.enqueue("b", owner: second)
        queue.enqueue("c", owner: first)
        #expect(queue.removeAll(owner: first) == ["a", "c"])
        #expect(queue.current == "b")
    }

    @Test func removingEverythingReturnsEveryPromptInOrder() {
        var queue = PromptQueue<Int>()
        queue.enqueue(1, owner: first)
        queue.enqueue(2, owner: second)
        #expect(queue.removeAll() == [1, 2])
        #expect(queue.isEmpty)
    }

    @Test func answeringAnEmptyQueueReturnsNothing() {
        var queue = PromptQueue<Int>()
        #expect(queue.removeCurrent() == nil)
    }
}
