import Testing

@testable import PeeringKit
@testable import RemoteCore

@Suite struct AgentChatEndingTests {
    private func transcript(_ payloads: [AgentStreamEvent.Payload]) -> AgentTranscript {
        var transcript = AgentTranscript()
        for payload in payloads { transcript.apply(payload) }
        return transcript
    }

    @Test func aChatIsPausedWhileThePauseNoticeIsLast() {
        var paused = transcript([.userPrompt(text: "hi"), .notice(text: AgentPause.notice)])
        #expect(AgentPause.isPaused(paused))
        paused.apply(.userPrompt(text: "again"))
        #expect(!AgentPause.isPaused(paused))
    }

    @Test func theCLIsRefusalToResumeIsRecognised() {
        #expect(AgentExpiry.isResumeRefusal(stderr: "No conversation found with session ID: abc"))
        #expect(!AgentExpiry.isResumeRefusal(stderr: "network unreachable"))
    }

    @Test func anExpiredChatIsOneWhoseFailureIsTheExpiryMessage() {
        #expect(AgentExpiry.isExpired(transcript([.userPrompt(text: "hi"), .failure(message: AgentExpiry.message)])))
        #expect(!AgentExpiry.isExpired(transcript([.userPrompt(text: "hi"), .failure(message: "something else")])))
    }

    @Test func theRecapKeepsTheLastThreeExchanges() {
        var events: [AgentStreamEvent.Payload] = []
        for number in 1...5 {
            events.append(.userPrompt(text: "question \(number)"))
            events.append(.textFinal(text: "answer \(number)"))
        }
        let recap = AgentRecap.text(from: transcript(events)) ?? ""
        #expect(recap.contains("I asked: question 5"))
        #expect(recap.contains("You answered: answer 3"))
        #expect(!recap.contains("question 2"))
        #expect(recap.hasSuffix("Please carry on from here."))
    }

    @Test func aLongReplyIsCutInTheRecap() {
        let recap = AgentRecap.text(from: transcript([.userPrompt(text: "go"), .textFinal(text: String(repeating: "x", count: 900))])) ?? ""
        #expect(recap.contains("…"))
        #expect(recap.count < 700)
    }

    @Test func anEmptyChatHasNothingToRecap() {
        #expect(AgentRecap.text(from: transcript([])) == nil)
    }
}
