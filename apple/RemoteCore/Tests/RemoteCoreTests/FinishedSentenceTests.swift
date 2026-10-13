import Testing
@testable import RemoteCore

@Suite("Finished sentence")
struct FinishedSentenceTests {
    @Test("a command that finished is read with its duration")
    func readsCommand() {
        let sentence = FinishedSentence(parsing: "\u{201C}npm run build\u{201D} finished after 2m 5s.")
        #expect(sentence?.subject == .command("npm run build"))
        #expect(sentence?.seconds == 125)
    }

    @Test("a terminal without a command is read by its name")
    func readsTerminal() {
        let sentence = FinishedSentence(parsing: "Terminal \u{201C}prod\u{201D} finished after 4s.")
        #expect(sentence?.subject == .terminal(name: "prod"))
        #expect(sentence?.seconds == 4)
    }

    @Test("a command that contains the joining words keeps them")
    func commandWithSeparatorInside() {
        let sentence = FinishedSentence(parsing: "\u{201C}echo \u{201D} finished after 1s\u{201D} finished after 3s.")
        #expect(sentence?.subject == .command("echo \u{201D} finished after 1s"))
        #expect(sentence?.seconds == 3)
    }

    @Test("a duration in another language is kept as the Mac wrote it")
    func unreadableDurationIsKept() {
        let sentence = FinishedSentence(parsing: "\u{201C}ls\u{201D} finished after 2 Min. 5 Sek..")
        #expect(sentence?.duration == "2 Min. 5 Sek.")
        #expect(sentence?.seconds == nil)
    }

    @Test("other sentences are not read", arguments: [
        "", "finished after 4s.", "\u{201C}ls\u{201D} finished after 4s", "\u{201C}ls\u{201D} finished after .",
        "Something \u{201C}ls\u{201D} finished after 4s.",
    ])
    func rejectsOthers(text: String) {
        #expect(FinishedSentence(parsing: text) == nil)
    }
}
