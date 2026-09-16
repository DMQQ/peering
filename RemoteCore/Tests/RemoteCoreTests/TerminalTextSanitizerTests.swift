import Foundation
import Testing

@testable import RemoteCore

/// What a PTY's byte stream becomes on screen.
///
/// These exist because the answer was wrong in a way that read as a rendering fault rather than
/// as a parsing one: every line of a shell's output ran into the next, so a terminal looked like
/// a single unbroken string of text. The cause was a Swift subtlety worth a test of its own —
/// `"\r\n"` is a *single* `Character` — so the loop matched neither `\r` nor `\n` and dropped the
/// pair as control characters.
@Suite("Terminal text")
struct TerminalTextSanitizerTests {
    private func render(_ text: String) -> String {
        TerminalTextSanitizer.render(Data(text.utf8))
    }

    @Test("a CRLF line ending ends the line")
    func carriageReturnLineFeed() {
        // The regression. A default PTY maps newline to CRLF on output, so this is the shape of
        // all of it — not an edge case.
        #expect(render("hello\r\nworld\r\n") == "hello\nworld\n")
    }

    @Test("a bare line feed ends the line too")
    func bareLineFeed() {
        #expect(render("hello\nworld\n") == "hello\nworld\n")
    }

    @Test("a prompt and a command land on their own lines")
    func promptAndCommand() {
        #expect(render("damian@Mac ~ % \r\nls\r\nfile.txt\r\n") == "damian@Mac ~ % \nls\nfile.txt\n")
    }

    @Test("a progress bar keeps its last value and nothing behind it")
    func progressRedraw() {
        // The case the carriage-return handling exists for: each frame writes over the last.
        #expect(render("10%\r20%\r100%\r\ndone\r\n") == "100%\ndone\n")
    }

    @Test("a shorter rewrite leaves no tail of the line it replaced")
    func shorterRewrite() {
        #expect(render("abcdef\rxy\n") == "xy\n")
    }

    @Test("colour codes are removed rather than printed")
    func ansiColours() {
        // The pattern used to spell the escape as `\u{001B}` inside the regex, which the engine
        // reads as six literal characters — so nothing matched and the codes arrived as text.
        #expect(render("\u{001B}[32mgreen\u{001B}[0m\r\n") == "green\n")
    }

    @Test("a backspace removes the character before it")
    func backspace() {
        #expect(render("helo\u{08}lo\r\n") == "hello\n")
    }

    @Test("a line the shell refused is marked as an error")
    func unknownCommandIsAnError() {
        let lines = TerminalTextSanitizer.renderLines(Data("ls\r\nzsh: command not found: lss\r\n".utf8))
        #expect(lines.map(\.kind) == [.plain, .error, .plain])
    }

    @Test("a warning is marked as a warning, not as a failure")
    func warningLine() {
        let lines = TerminalTextSanitizer.renderLines(Data("warning: unused variable 'x'\r\n".utf8))
        #expect(lines.first?.kind == .warning)
    }

    @Test("a file that merely has error in its name is not coloured")
    func errorInAFilename() {
        // The reason the signals are phrases rather than words: a listing is full of names like
        // this one, and a rule that matched "error" would colour half of a directory listing.
        let lines = TerminalTextSanitizer.renderLines(Data("error.log  notes.txt\r\n".utf8))
        #expect(lines.first?.kind == .plain)
    }

    @Test("only the shell's own refusal counts as an unknown command")
    func unknownCommandDetection() {
        #expect(TerminalTextSanitizer.reportsUnknownCommand(Data("zsh: command not found: foo\r\n".utf8)))
        // A command that ran and failed is a command, and is kept.
        #expect(!TerminalTextSanitizer.reportsUnknownCommand(Data("make: *** [all] Error 2\r\n".utf8)))
        #expect(!TerminalTextSanitizer.reportsUnknownCommand(Data("everything is fine\r\n".utf8)))
    }

    @Test("output that spans several reads still renders")
    func splitReads() {
        // The history is re-rendered from the whole buffer on every read, so a line split across
        // two reads is the normal case rather than a special one.
        #expect(render("first half") == "first half")
        #expect(render("first half second half\r\n") == "first half second half\n")
    }
}
