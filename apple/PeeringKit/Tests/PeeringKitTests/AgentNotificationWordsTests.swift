import Foundation
import RemoteCore
import Testing

@testable import PeeringKit

@Suite struct AgentNotificationWordsTests {
    private let words = AgentNotificationWords(
        asks: { "\($0) wonders" },
        needsApproval: "Wants a nod.",
        title: { name, outcome in "\(name) \(outcome)" },
        turn: { outcome in "turn \(outcome)" },
        filesChanged: { "\($0) files touched" },
        duration: { "\(Int($0)) ticks" },
        claudeCode: "Claude",
        claudeCodeIn: { "Claude at \($0)" },
        claudeCodeWaiting: "Claude waits."
    )

    @Test func anApprovalUsesTheSuppliedWords() {
        let text = AgentNotificationText.approval(agentName: "Codex", reason: nil, detail: nil, words: words)
        #expect(text.title == "Codex wonders")
        #expect(text.body == "Wants a nod.")
    }

    @Test func aFinishedTurnUsesTheSuppliedWordsForTitleHeadlineAndDigest() {
        let text = AgentNotificationText.finished(
            agentName: "A", ok: false, stopped: true, lastReply: nil, editedFiles: 2, duration: 90, words: words
        )
        #expect(text.title == "A stopped")
        #expect(text.body == "turn stopped\n2 files touched · 90 ticks")
    }

    @Test func englishIsTheDefaultWhenNoWordsAreGiven() {
        #expect(AgentNotificationText.approval(agentName: "A", reason: nil, detail: nil).title == "A asks")
        #expect(AgentNotificationWords.english.claudeCodeIn("site") == "Claude Code in site")
    }

    @Test func aHookPushUsesTheSuppliedWordsForItsTitle() {
        let recorder = PushRecorder()
        let broker = ClaudeHookBroker(
            tokens: { ["token"] },
            push: { _, title, body, _ in recorder.add(title, body) },
            words: words
        )
        let event = ClaudeHookEvent(
            kind: .notification, sessionID: "s", directory: "/Users/x/site", toolName: nil, detail: nil, message: nil
        )
        broker.handle(event) { _ in }
        #expect(recorder.pushes.first?.title == "Claude at site")
        #expect(recorder.pushes.first?.body == "Claude waits.")
    }
}

private final class PushRecorder: @unchecked Sendable {
    private let lock = NSLock()
    /// Guarded by `lock`.
    private var recorded: [(title: String, body: String)] = []

    var pushes: [(title: String, body: String)] { lock.withLock { recorded } }

    func add(_ title: String, _ body: String) {
        lock.withLock { recorded.append((title, body)) }
    }
}
