import Foundation
import RemoteCore
import Testing

@testable import PeeringKit

@Suite("Live Activity chat tracker")
struct LiveActivityChatTrackerTests {
    private let t0 = ContinuousClock.now

    private func observe(_ tracker: inout LiveActivityChatTracker, _ states: [(String, AgentSessionState)], at offset: TimeInterval = 0) -> [LiveActivityChat] {
        tracker.observe(states.map { .init(id: $0.0, state: $0.1) }, symbol: "s", now: t0.addingTimeInterval(offset))
    }

    @Test("chats that were idle before anyone looked are not listed")
    func idleFromTheStart() {
        var tracker = LiveActivityChatTracker()
        #expect(observe(&tracker, [("a", .idle), ("b", .failed), ("c", .exited)]).isEmpty)
    }

    @Test("a busy chat is listed by what it is doing")
    func busy() {
        var tracker = LiveActivityChatTracker()
        let chats = observe(&tracker, [("a", .working), ("b", .awaitingApproval)])
        #expect(chats.map(\.state) == [.working, .needsYou])
    }

    @Test("a chat that stops working is listed as finished, and a failed one as failed")
    func stops() {
        var tracker = LiveActivityChatTracker()
        _ = observe(&tracker, [("a", .working), ("b", .working)])
        let chats = observe(&tracker, [("a", .idle), ("b", .failed)], at: 5)
        #expect(Set(chats.map(\.state)) == [.finished, .failed])
    }

    @Test("the one that stopped last is listed first")
    func newestFirst() {
        var tracker = LiveActivityChatTracker()
        _ = observe(&tracker, [("a", .working), ("b", .working)])
        _ = observe(&tracker, [("a", .idle), ("b", .working)], at: 5)
        let chats = observe(&tracker, [("a", .idle), ("b", .idle)], at: 9)
        #expect(chats.map(\.id) == ["b", "a"])
    }

    @Test("a stopped chat leaves the list after thirty minutes")
    func expires() {
        var tracker = LiveActivityChatTracker()
        _ = observe(&tracker, [("a", .working)])
        _ = observe(&tracker, [("a", .idle)], at: 1)
        #expect(observe(&tracker, [("a", .idle)], at: 1 + 30 * 60 - 1).count == 1)
        #expect(observe(&tracker, [("a", .idle)], at: 1 + 30 * 60).isEmpty)
    }

    @Test("new work on a stopped chat replaces its stopped state")
    func resumed() {
        var tracker = LiveActivityChatTracker()
        _ = observe(&tracker, [("a", .working)])
        _ = observe(&tracker, [("a", .idle)], at: 2)
        #expect(observe(&tracker, [("a", .working)], at: 4).map(\.state) == [.working])
    }

    @Test("a closed chat is forgotten")
    func closed() {
        var tracker = LiveActivityChatTracker()
        _ = observe(&tracker, [("a", .working)])
        _ = observe(&tracker, [("a", .idle)], at: 2)
        #expect(observe(&tracker, [], at: 3).isEmpty)
    }
}
