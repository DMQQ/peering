import Foundation
import RemoteCore
import Testing

@testable import PeeringKit

struct ChatWatchTests {
    private func transcript(_ payloads: [AgentStreamEvent.Payload]) -> AgentTranscript {
        var transcript = AgentTranscript()
        for payload in payloads { transcript.apply(payload) }
        return transcript
    }

    private let done = AgentStreamEvent.Payload.turnFinished(summary: AgentTurnSummary(ok: true))

    @Test func aFinishedTurnWithAReplyOffersWatching() {
        #expect(ChatWatch.isOffered(for: transcript([.userPrompt(text: "fix it"), .textDelta(text: "Done."), done])))
    }

    @Test func aWorkingTurnDoesNotOfferWatching() {
        #expect(!ChatWatch.isOffered(for: transcript([.userPrompt(text: "fix it"), .textDelta(text: "On it")])))
    }

    @Test func aNewPromptWithoutAReplyYetDoesNotOfferWatching() {
        #expect(!ChatWatch.isOffered(for: transcript([.userPrompt(text: "fix it")])))
    }

    @Test func anEmptyChatDoesNotOfferWatching() {
        #expect(!ChatWatch.isOffered(for: AgentTranscript()))
    }

    @Test func workspaceIsRestoredAfterWatching() {
        let watch = ChatWatch(chatID: UUID(), sessionID: UUID(), previousMode: .workspace)
        #expect(watch.watchingMode == .screen)
        #expect(watch.modeToRestore == .workspace)
    }

    @Test func screenModeHasNothingToRestore() {
        #expect(ChatWatch(chatID: UUID(), sessionID: UUID(), previousMode: .screen).modeToRestore == nil)
    }
}
