import Foundation
import Testing

@testable import PeeringKit

struct ChatChangeClockPruneTests {
    @Test func keepingOnlyLiveChatsForgetsAClosedOne() {
        let open = UUID()
        let closed = UUID()
        var clock = ChatChangeClock()
        let start = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        for id in [open, closed] {
            clock.observe(id, fingerprint: "a", at: start)
            clock.observe(id, fingerprint: "b", at: later)
        }
        clock.keepOnly([open])
        #expect(clock.isUnread(open))
        #expect(!clock.isUnread(closed))
        #expect(clock.changedAt(closed, fallback: start) == start)
    }

    @Test func keepingEveryChatChangesNothing() {
        let id = UUID()
        var clock = ChatChangeClock()
        clock.observe(id, fingerprint: "a", at: Date(timeIntervalSince1970: 1_000))
        let before = clock
        clock.keepOnly([id])
        #expect(clock == before)
    }
}
