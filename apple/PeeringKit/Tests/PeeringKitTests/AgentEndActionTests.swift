import Testing
@testable import PeeringKit

@Suite("Ending a chat")
struct AgentEndActionTests {
    private func action(conversation: Bool = true, working: Bool = false, paused: Bool = false, supported: Bool = true) -> AgentEndAction {
        AgentEndAction.choose(hasConversation: conversation, isWorking: working, isPaused: paused, hostSupportsPause: supported)
    }

    @Test func aChatWithAConversationMovesToHistory() {
        #expect(action() == .pause)
    }

    @Test func anEmptyChatIsDeleted() {
        #expect(action(conversation: false) == .close)
    }

    @Test func aWorkingChatIsDeletedBecauseTheMacRefusesToPauseIt() {
        #expect(action(working: true) == .close)
    }

    @Test func aHostThatCannotPauseStillDeletes() {
        #expect(action(supported: false) == .close)
    }

    @Test func aPausedChatIsDeletedWhenEndedAgain() {
        #expect(action(paused: true) == .close)
    }
}
