import Foundation
import Testing

@testable import RemoteCore

@Suite("Terminal screen colour")
struct TerminalScreenStyleTests {
    // MARK: - The codes

    @Test("a red foreground is an indexed run that a reset ends")
    func redForeground() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("\u{1B}[31mred\u{1B}[0mplain".utf8))
        #expect(screen.styled[0].runs == [
            TerminalRun(text: "red", foreground: .indexed(1), background: .default, bold: false, dim: false),
            TerminalRun(text: "plain", foreground: .default, background: .default, bold: false, dim: false),
        ])
    }

    @Test("bold and a colour in one sequence are both set")
    func boldAndColourTogether() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("\u{1B}[1;31mred".utf8))
        #expect(screen.styled[0].runs == [
            TerminalRun(text: "red", foreground: .indexed(1), background: .default, bold: true, dim: false),
        ])
    }

    @Test("a reset in the middle of a sequence leaves the codes before it in force")
    func resetIsAParameterLikeAnyOther() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("\u{1B}[1;0;31mred".utf8))
        #expect(screen.styled[0].runs == [
            TerminalRun(text: "red", foreground: .indexed(1), background: .default, bold: false, dim: false),
        ])
    }

    @Test("a bare CSI m is a reset")
    func bareReset() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("\u{1B}[31mred\u{1B}[mplain".utf8))
        #expect(screen.styled[0].runs.map(\.foreground) == [.indexed(1), .default])

        var interior = TerminalScreen(columns: 20, rows: 4)
        interior.feed(Data("\u{1B}[1;;31mred".utf8))
        #expect(interior.styled[0].runs == [
            TerminalRun(text: "red", foreground: .indexed(1), background: .default, bold: false, dim: false),
        ])
    }

    @Test("the sixteen named colours land in the 256-colour index space")
    func namedColours() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("\u{1B}[31mA\u{1B}[91mB\u{1B}[41mC\u{1B}[101mD\u{1B}[39mE\u{1B}[49mF".utf8))
        #expect(screen.styled[0].runs == [
            TerminalRun(text: "A", foreground: .indexed(1), background: .default, bold: false, dim: false),
            TerminalRun(text: "B", foreground: .indexed(9), background: .default, bold: false, dim: false),
            TerminalRun(text: "C", foreground: .indexed(9), background: .indexed(1), bold: false, dim: false),
            TerminalRun(text: "D", foreground: .indexed(9), background: .indexed(9), bold: false, dim: false),
            TerminalRun(text: "E", foreground: .default, background: .indexed(9), bold: false, dim: false),
            TerminalRun(text: "F", foreground: .default, background: .default, bold: false, dim: false),
        ])
    }

    @Test("dim is set by 2 and cleared by 22 without touching the colour")
    func intensity() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("\u{1B}[2;32mdim\u{1B}[22mnormal".utf8))
        #expect(screen.styled[0].runs == [
            TerminalRun(text: "dim", foreground: .indexed(2), background: .default, bold: false, dim: true),
            TerminalRun(text: "normal", foreground: .indexed(2), background: .default, bold: false, dim: false),
        ])
    }

    @Test("a 256-colour sequence is one colour, not three codes")
    func indexedColour() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("\u{1B}[38;5;208morange".utf8))
        #expect(screen.styled[0].runs == [
            TerminalRun(text: "orange", foreground: .indexed(208), background: .default, bold: false, dim: false),
        ])

        // The `5` is consumed as part of the sequence; read as a code it would be blink.
        var values = TerminalScreen(columns: 20, rows: 4)
        values.feed(Data("\u{1B}[38;5;5mfifth\u{1B}[48;5;9;1mbar".utf8))
        #expect(values.styled[0].runs == [
            TerminalRun(text: "fifth", foreground: .indexed(5), background: .default, bold: false, dim: false),
            TerminalRun(text: "bar", foreground: .indexed(5), background: .indexed(9), bold: true, dim: false),
        ])

        var prefixed = TerminalScreen(columns: 20, rows: 4)
        prefixed.feed(Data("\u{1B}[0;38;5;208morange".utf8))
        #expect(prefixed.styled[0].runs == [
            TerminalRun(text: "orange", foreground: .indexed(208), background: .default, bold: false, dim: false),
        ])
    }

    @Test("a truecolour sequence gives 24-bit colour")
    func trueColour() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("\u{1B}[38;2;10;20;30mdeep\u{1B}[48;2;40;50;60msea".utf8))
        #expect(screen.styled[0].runs == [
            TerminalRun(text: "deep", foreground: .rgb(10, 20, 30), background: .default, bold: false, dim: false),
            TerminalRun(text: "sea", foreground: .rgb(10, 20, 30), background: .rgb(40, 50, 60), bold: false, dim: false),
        ])

        var outOfRange = TerminalScreen(columns: 20, rows: 4)
        outOfRange.feed(Data("\u{1B}[38;2;300;0;0;31mred".utf8))
        #expect(outOfRange.styled[0].runs == [
            TerminalRun(text: "red", foreground: .indexed(1), background: .default, bold: false, dim: false),
        ])
    }

    @Test("a colour sequence that was cut off leaves the text after it alone")
    func truncatedColour() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("\u{1B}[38;5mplain\u{1B}[38;2;10;20mx".utf8))
        #expect(screen.visible == ["plainx"])
        #expect(screen.styled[0].runs.map(\.foreground) == [.default])
    }

    // MARK: - What is ignored

    @Test("an unsupported SGR is ignored and the text after it still renders")
    func unknownSequence() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("\u{1B}[4munder\u{1B}[0m\u{1B}[4:3mcurly\u{1B}[K".utf8))
        #expect(screen.visible == ["undercurly"])
        #expect(screen.styled[0].runs == [
            TerminalRun(text: "undercurly", foreground: .default, background: .default, bold: false, dim: false),
        ])
    }

    @Test("a code nobody knows cannot shift what the numbers after it mean")
    func unknownSequenceDoesNotDesynchronise() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("\u{1B}[7;5;9;58;5;196;31mred\u{1B}[0m plain".utf8))
        #expect(screen.styled[0].runs == [
            TerminalRun(text: "red", foreground: .indexed(1), background: .default, bold: false, dim: false),
            TerminalRun(text: " plain", foreground: .default, background: .default, bold: false, dim: false),
        ])
    }

    @Test("an SGR split across two reads is still one sequence")
    func splitSequence() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("\u{1B}[38;".utf8))
        #expect(screen.styled.isEmpty)
        screen.feed(Data("5;208mhot".utf8))
        #expect(screen.styled[0].runs == [
            TerminalRun(text: "hot", foreground: .indexed(208), background: .default, bold: false, dim: false),
        ])
    }

    // MARK: - Colour belongs to a cell

    @Test("a cell keeps the colour it was written in when another row is repainted")
    func colourIsPerCell() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("\u{1B}[32mhead\u{1B}[2;1H\u{1B}[31mbody".utf8))
        #expect(screen.styled[0].runs.map(\.foreground) == [.indexed(2)])
        #expect(screen.styled[1].runs.map(\.foreground) == [.indexed(1)])

        screen.feed(Data("\u{1B}[1;1H\u{1B}[33mHEAD".utf8))
        #expect(screen.visible == ["HEAD", "body"])
        #expect(screen.styled[0].runs.map(\.foreground) == [.indexed(3)])
        #expect(screen.styled[1].runs.map(\.foreground) == [.indexed(1)])

        var repaint = TerminalScreen(columns: 20, rows: 4)
        repaint.feed(Data("\u{1B}[31mred\u{1B}[1G\u{1B}[33mye".utf8))
        #expect(repaint.styled[0].runs == [
            TerminalRun(text: "ye", foreground: .indexed(3), background: .default, bold: false, dim: false),
            TerminalRun(text: "d", foreground: .indexed(1), background: .default, bold: false, dim: false),
        ])
    }

    @Test("erasing a line puts the erased cells back to the default style")
    func eraseResetsToDefaultStyle() {
        var screen = TerminalScreen(columns: 10, rows: 4)
        // An erase must not use the pen's colour, or the row below an `htop` frame stays tinted.
        screen.feed(Data("\u{1B}[41mred\u{1B}[1G\u{1B}[K".utf8))
        #expect(screen.styled.isEmpty)

        var partial = TerminalScreen(columns: 10, rows: 4)
        partial.feed(Data("\u{1B}[31mabc\u{1B}[2G\u{1B}[K".utf8))
        #expect(partial.styled[0].runs == [
            TerminalRun(text: "a", foreground: .indexed(1), background: .default, bold: false, dim: false),
        ])
    }

    @Test("erasing the screen puts the erased cells back to the default style")
    func eraseDisplayResetsToDefaultStyle() {
        var screen = TerminalScreen(columns: 5, rows: 3)
        screen.feed(Data("\u{1B}[44maa\r\nbb\r\ncc\u{1B}[H\u{1B}[J".utf8))
        #expect(screen.styled.isEmpty)
        #expect(screen.visible.isEmpty)
    }

    @Test("a row that scrolls off carries its colour into the scrollback")
    func scrollbackKeepsStyle() {
        var screen = TerminalScreen(columns: 10, rows: 2)
        screen.feed(Data("\u{1B}[31mred\u{1B}[0m\r\nplain\r\nthird".utf8))
        #expect(screen.scrollback == ["red"])
        #expect(screen.styled.map(\.text) == ["red", "plain", "third"])
        #expect(screen.styled[0].runs == [
            TerminalRun(text: "red", foreground: .indexed(1), background: .default, bold: false, dim: false),
        ])
        #expect(screen.styled[1].runs == [
            TerminalRun(text: "plain", foreground: .default, background: .default, bold: false, dim: false),
        ])
    }

    @Test("the alternate screen starts from a default pen")
    func alternateScreenResetsPen() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("\u{1B}[31mred\u{1B}[?1049hplain".utf8))
        #expect(screen.styled[0].runs == [
            TerminalRun(text: "plain", foreground: .default, background: .default, bold: false, dim: false),
        ])
    }

    // MARK: - Shape of the output

    @Test("runs are coalesced, so a plain row is one run and not one per character")
    func runsAreCoalesced() {
        var screen = TerminalScreen(columns: 80, rows: 24)
        screen.feed(Data(String(repeating: "x", count: 80).utf8))
        #expect(screen.styled.count == 1)
        #expect(screen.styled[0].runs.count == 1)
        #expect(screen.styled[0].runs[0].text == String(repeating: "x", count: 80))

        var mixed = TerminalScreen(columns: 20, rows: 4)
        mixed.feed(Data("\u{1B}[31mab\u{1B}[1mcd".utf8))
        #expect(mixed.styled[0].runs.count == 2)
        #expect(mixed.styled[0].runs.map(\.text) == ["ab", "cd"])
    }

    @Test("only an uncoloured space is padding")
    func colouredBlanksAreKept() {
        var screen = TerminalScreen(columns: 6, rows: 2)
        // A bar is blank cells with a background; trimming the row like padding would erase it.
        screen.feed(Data("\u{1B}[42m   \u{1B}[0m".utf8))
        #expect(screen.styled[0].runs == [
            TerminalRun(text: "   ", foreground: .default, background: .indexed(2), bold: false, dim: false),
        ])
        #expect(screen.visible == ["   "])
    }

    @Test("a line that was never coloured is classified the way it always was")
    func kindSurvives() {
        var screen = TerminalScreen(columns: 32, rows: 3)
        screen.feed(Data("zsh: command not found: foo\r\nwarning: deprecated\r\nok".utf8))
        #expect(screen.styled.map(\.kind) == [
            TerminalTextSanitizer.Kind.error,
            TerminalTextSanitizer.Kind.warning,
            TerminalTextSanitizer.Kind.plain,
        ])
        #expect(screen.lines.map(\.text) == screen.styled.map(\.text))
        #expect(screen.lines.map(\.kind) == screen.styled.map(\.kind))
    }

    @Test("the styled lines are the scrollback and then the screen")
    func styledLinesIncludeScrollback() {
        var screen = TerminalScreen(columns: 10, rows: 2)
        screen.feed(Data("\u{1B}[32mgreen\r\nplain\r\nlast".utf8))
        #expect(screen.styled.map(\.text) == ["green", "plain", "last"])
        #expect(screen.styled[0].runs.map(\.foreground) == [.indexed(2)])
        #expect(screen.visible == ["plain", "last"])
    }
}
