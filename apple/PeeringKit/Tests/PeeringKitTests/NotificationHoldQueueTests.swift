import Foundation
import Testing

@testable import PeeringKit

struct NotificationHoldQueueTests {
    private let start = ContinuousClock.now

    @Test func anOldNotificationIsNotDeliveredAfterItsLifetime() {
        var queue = NotificationHoldQueue<String>()
        _ = queue.add("old", token: "a", source: "s1", answerable: false, now: start)
        _ = queue.add("new", token: "a", source: "s2", answerable: false, now: start.addingTimeInterval(500))

        let drained = queue.drain(now: start.addingTimeInterval(700))
        #expect(drained.map(\.item) == ["new"])
    }

    @Test func aSecondPlainNotificationFromOneSessionWithinTheCooldownIsHeldBack() {
        var queue = NotificationHoldQueue<String>()
        #expect(queue.add("one", token: "a", source: "s1", answerable: false, now: start) == 0)
        #expect(queue.add("two", token: "a", source: "s1", answerable: false, now: start.addingTimeInterval(1)) == nil)
        #expect(queue.add("three", token: "a", source: "s1", answerable: false, now: start.addingTimeInterval(6)) == 0)
        #expect(queue.drain(now: start.addingTimeInterval(7)).map(\.item) == ["one", "three"])
    }

    @Test func theCooldownIsPerSession() {
        var queue = NotificationHoldQueue<String>()
        _ = queue.add("one", token: "a", source: "s1", answerable: false, now: start)
        #expect(queue.add("two", token: "a", source: "s2", answerable: false, now: start) == 0)
    }

    @Test func aNotificationThatCarriesAnActionIsNeverHeldBack() {
        var queue = NotificationHoldQueue<String>()
        _ = queue.add("one", token: "a", source: "s1", answerable: true, now: start)
        #expect(queue.add("two", token: "a", source: "s1", answerable: true, now: start) == 0)
        #expect(queue.count == 2)
    }

    @Test func oneTokenCannotCrowdOutTheOthers() {
        var queue = NotificationHoldQueue<String>()
        _ = queue.add("other", token: "b", source: nil, answerable: true, now: start)
        for index in 0..<6 {
            _ = queue.add("a\(index)", token: "a", source: nil, answerable: true, now: start)
        }
        let items = queue.drain(now: start).map(\.item)
        #expect(items == ["other", "a2", "a3", "a4", "a5"])
    }

    @Test func theQueueNeverExceedsItsCapacity() {
        var queue = NotificationHoldQueue<Int>()
        for index in 0..<40 {
            _ = queue.add(index, token: "t\(index)", source: nil, answerable: true, now: start)
        }
        #expect(queue.count == 16)
        #expect(queue.drain(now: start).first?.item == 24)
    }

    @Test func aForgottenTokenLosesItsHeldNotifications() {
        var queue = NotificationHoldQueue<String>()
        _ = queue.add("gone", token: "a", source: nil, answerable: true, now: start)
        _ = queue.add("kept", token: "b", source: nil, answerable: true, now: start)
        queue.forget(token: "a")
        #expect(queue.drain(now: start).map(\.item) == ["kept"])
    }

    @Test func requeuedEntriesComeBeforeNewerOnes() {
        var queue = NotificationHoldQueue<String>()
        _ = queue.add("first", token: "a", source: nil, answerable: true, now: start)
        let taken = queue.drain(now: start)
        _ = queue.add("second", token: "b", source: nil, answerable: true, now: start)
        queue.requeue(taken)
        #expect(queue.drain(now: start).map(\.item) == ["first", "second"])
    }
}
