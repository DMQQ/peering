import Foundation
import Testing
@testable import RemoteCore

@Suite("Terminal attention detector")
struct TerminalAttentionDetectorTests {
    @Test("Claude permission choices ask for attention")
    func detectsClaudePermissionChoice() {
        var detector = TerminalAttentionDetector()

        let prompt = """
        Do you want to proceed?
        ❯ 1. Yes
          2. Yes, and don't ask again
          3. No
        Esc to cancel
        """

        #expect(detector.receive(Data(prompt.utf8)) == .confirmation)
    }

    @Test("Claude multiple-choice questions ask for attention")
    func detectsClaudeQuestionChoice() {
        var detector = TerminalAttentionDetector()
        let prompt = """
        Which deployment should I use?
        ❯ 1. Staging
          2. Production
          3. Let me type another answer
        """

        #expect(detector.receive(Data(prompt.utf8)) == .confirmation)
    }

    @Test("a prompt split between SSH packets is detected only when complete")
    func detectsSplitPrompt() {
        var detector = TerminalAttentionDetector()

        #expect(detector.receive(Data("Do you want to pro".utf8)) == nil)
        #expect(detector.receive(Data("ceed?\r\n\u{001B}[36m❯ 1. Yes\u{001B}[0m\r\n  2. No".utf8)) == .confirmation)
    }

    @Test("a redrawn prompt notifies once until the user responds")
    func suppressesPromptRedraws() {
        var detector = TerminalAttentionDetector()
        let prompt = Data("Allow this tool?\r\n❯ 1. Yes\r\n  2. No".utf8)

        #expect(detector.receive(prompt) == .confirmation)
        #expect(detector.receive(prompt) == nil)

        detector.userDidRespond()

        #expect(detector.receive(prompt) == .confirmation)
    }

    @Test("password and conventional confirmation prompts still ask for attention")
    func detectsConventionalPrompts() {
        var password = TerminalAttentionDetector()
        var confirmation = TerminalAttentionDetector()

        #expect(password.receive(Data("Password for deploy@example.com: ".utf8)) == .password)
        #expect(confirmation.receive(Data("Continue? [y/N] ".utf8)) == .confirmation)
    }

    @Test("the prompt that asked is what the notification quotes")
    func quotesThePromptThatAsked() {
        var sudo = TerminalAttentionDetector()
        #expect(sudo.receive(Data("$ ls\r\n[sudo] password for damian: ".utf8)) == .password)
        // The prompt itself, rather than the last line of ordinary output, and with the terminal's
        // colouring taken off: this is what goes in a sentence read on a locked screen.
        #expect(sudo.question == "[sudo] password for damian:")

        var coloured = TerminalAttentionDetector()
        #expect(
            coloured.receive(Data("deploy@example.com's password:\u{001B}[0m ".utf8)) == .password
        )
        #expect(coloured.question == "deploy@example.com's password:")
    }

    @Test("a question that cannot be read is not guessed at")
    func refusesAnUnreadableQuestion() {
        // A program that repaints rather than prints leaves a screenful of single line behind it,
        // and the first eighty characters of that are not a sentence to put in a notification.
        var repainting = TerminalAttentionDetector()
        _ = repainting.receive(Data((String(repeating: "x", count: 200) + "\n").utf8))
        #expect(repainting.question == nil)

        // Control bytes survive no strip, because a cursor move is made of them.
        var animated = TerminalAttentionDetector()
        _ = animated.receive(Data("Password: \u{0007}".utf8))
        #expect(animated.question == nil)
    }

    @Test("ordinary questions and numbered output do not ask for attention")
    func ignoresOrdinaryOutput() {
        var question = TerminalAttentionDetector()
        var numbered = TerminalAttentionDetector()

        #expect(question.receive(Data("What changed in this release?\r\n".utf8)) == nil)
        #expect(numbered.receive(Data("1. Build\r\n2. Test\r\n3. Ship\r\n".utf8)) == nil)
    }
}
