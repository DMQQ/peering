import Foundation
import Testing
@testable import PeeringKit

struct ConversationOpenElsewhereTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func aFileWrittenAMomentAgoByNobodyWeKnowIsLikelyOpen() {
        #expect(ConversationOpenElsewhere.isLikely(modified: now.addingTimeInterval(-10), now: now, releasedAt: nil))
    }

    @Test func anOldFileIsNotOpen() {
        #expect(!ConversationOpenElsewhere.isLikely(modified: now.addingTimeInterval(-600), now: now, releasedAt: nil))
    }

    @Test func theLastWriteOfAChatWeJustClosedIsOurOwn() {
        let released = now.addingTimeInterval(-20)
        #expect(!ConversationOpenElsewhere.isLikely(modified: released.addingTimeInterval(2), now: now, releasedAt: released))
    }

    @Test func aWriteAfterWeClosedItIsSomeoneElses() {
        let released = now.addingTimeInterval(-60)
        #expect(ConversationOpenElsewhere.isLikely(modified: now.addingTimeInterval(-10), now: now, releasedAt: released))
    }
}
