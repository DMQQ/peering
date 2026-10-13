import Testing

@testable import PeeringKit

struct AgentChatPhaseTests {
    @Test func aConversationAlwaysShows() {
        #expect(AgentChatPhase.of(transcriptIsEmpty: false, isLoaded: false, gaveUpLoading: false) == .conversation)
    }

    @Test func anEmptyUnreadChatIsLoadingNotEmpty() {
        #expect(AgentChatPhase.of(transcriptIsEmpty: true, isLoaded: false, gaveUpLoading: false) == .loading)
    }

    @Test func aLoadedEmptyChatIsEmpty() {
        #expect(AgentChatPhase.of(transcriptIsEmpty: true, isLoaded: true, gaveUpLoading: false) == .empty)
    }

    @Test func aHistoryThatNeverArrivedGivesUp() {
        #expect(AgentChatPhase.of(transcriptIsEmpty: true, isLoaded: false, gaveUpLoading: true) == .empty)
    }
}
