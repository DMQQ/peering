import Foundation
import Testing

@testable import PeeringKit

struct ChatWatchSessionTests {
    @Test func aVisitLastsWhileItsMacStaysOnScreen() {
        let mac = UUID()
        let watch = ChatWatch(chatID: UUID(), sessionID: mac, previousMode: .workspace)
        #expect(watch.isStillWatching(activeSessionID: mac))
    }

    @Test func switchingToAnotherMacEndsTheVisit() {
        let watch = ChatWatch(chatID: UUID(), sessionID: UUID(), previousMode: .workspace)
        #expect(!watch.isStillWatching(activeSessionID: UUID()))
        #expect(!watch.isStillWatching(activeSessionID: nil))
    }
}
