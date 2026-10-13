import Foundation
import Testing

@testable import PeeringKit

struct AgentHistoryRequestsTests {
    private let chat = UUID()

    @Test func anUnreadChatIsAskedForOnce() {
        var requests = AgentHistoryRequests()
        let first = requests.claim(chat, isLoaded: false, wireIsUp: true)
        let second = requests.claim(chat, isLoaded: false, wireIsUp: true)
        #expect(first)
        #expect(second == false)
    }

    @Test func anAskWhileTheWireIsDownIsNotRemembered() {
        var requests = AgentHistoryRequests()
        let early = requests.claim(chat, isLoaded: false, wireIsUp: false)
        let later = requests.claim(chat, isLoaded: false, wireIsUp: true)
        #expect(early == false)
        #expect(later)
    }

    @Test func aLoadedChatIsNeverAskedFor() {
        var requests = AgentHistoryRequests()
        let asked = requests.claim(chat, isLoaded: true, wireIsUp: true)
        #expect(asked == false)
    }

    @Test func aFreshListAllowsAskingAgain() {
        var requests = AgentHistoryRequests()
        _ = requests.claim(chat, isLoaded: false, wireIsUp: true)
        requests.removeAll()
        let again = requests.claim(chat, isLoaded: false, wireIsUp: true)
        #expect(again)
    }

    @Test func anAnsweredChatIsNotAskedAgainUntilTheListIsRefreshed() {
        var requests = AgentHistoryRequests()
        requests.markAnswered(chat)
        let asked = requests.claim(chat, isLoaded: false, wireIsUp: true)
        #expect(asked == false)
    }
}
