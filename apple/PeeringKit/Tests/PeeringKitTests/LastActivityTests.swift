import Foundation
import Testing

@testable import PeeringKit

@Suite struct LastActivityTests {
    private func defaults() -> UserDefaults {
        let name = "LastActivityTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    private func activity(at date: Date, id: UUID = UUID()) -> LastActivity {
        LastActivity(kind: .chat, id: id, hostID: "mac", title: "Fix login", openedAt: date)
    }

    @Test func itSurvivesASaveAndLoad() {
        let store = defaults()
        let saved = activity(at: Date(timeIntervalSince1970: 1_000))
        saved.save(to: store)
        #expect(LastActivity.load(from: store) == saved)
    }

    @Test func itGoesStaleAfterThreeDays() {
        let opened = Date(timeIntervalSince1970: 0)
        #expect(activity(at: opened).isFresh(at: opened.addingTimeInterval(2 * 24 * 3600)))
        #expect(!activity(at: opened).isFresh(at: opened.addingTimeInterval(4 * 24 * 3600)))
    }

    @Test func closingTheChatClearsItsRecordAndOnlyIts() {
        let store = defaults()
        let kept = activity(at: .now)
        kept.save(to: store)
        LastActivity.clear(UUID(), from: store)
        #expect(LastActivity.load(from: store) == kept)
        LastActivity.clear(kept.id, from: store)
        #expect(LastActivity.load(from: store) == nil)
    }
}
