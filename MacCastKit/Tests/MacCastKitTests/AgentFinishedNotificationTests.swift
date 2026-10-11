import Testing

@testable import MacCastKit

@Suite struct AgentFinishedNotificationTests {
    @Test func continueSendsAFixedPrompt() {
        #expect(AgentFinishedNotification.prompt(forActionIdentifier: "continue", userText: nil) == "Continue")
    }

    @Test func aReplySendsWhatWasTyped() {
        #expect(AgentFinishedNotification.prompt(forActionIdentifier: "reply", userText: "  run the tests \n") == "run the tests")
    }

    @Test func anEmptyReplySendsNothing() {
        #expect(AgentFinishedNotification.prompt(forActionIdentifier: "reply", userText: "   ") == nil)
        #expect(AgentFinishedNotification.prompt(forActionIdentifier: "reply", userText: nil) == nil)
    }

    @Test func aTapOnTheBodyIsNotAPrompt() {
        #expect(AgentFinishedNotification.prompt(forActionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", userText: "x") == nil)
    }
}
