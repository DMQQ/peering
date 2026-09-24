import Foundation
import Testing

@testable import RemoteCore

/// What a full-screen program's byte stream becomes.
///
/// These exist because the line-based renderer cannot draw one. It throws away cursor addressing
/// and appends whatever text is left, so `htop` arrives as a couple of mangled lines rather than as
/// a screen. The centre of gravity of the suite is the last test — a screen drawn the way `htop`
/// draws one — because that is the shape of the bug rather than an edge of it.
@Suite("Terminal screen")
struct TerminalScreenTests {
    @Test("plain text lands on the first row")
    func plainText() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("hello".utf8))
        #expect(screen.visible == ["hello"])
        #expect(screen.scrollback.isEmpty)
    }

    @Test("text past the last column wraps to the next row")
    func wrapping() {
        var screen = TerminalScreen(columns: 5, rows: 3)
        screen.feed(Data("abcdefghijkl".utf8))
        #expect(screen.visible == ["abcde", "fghij", "kl"])
    }

    @Test("a row filled exactly to the last column does not wrap on its own")
    func wrapIsDeferred() {
        // A full-screen program pads every row out to the full width, so a wrap that happened on
        // the write itself would scroll the screen every time the bottom-right cell was drawn —
        // one row of the frame lost per refresh, which reads as a rendering fault and is one.
        var screen = TerminalScreen(columns: 5, rows: 3)
        screen.feed(Data("abcde".utf8))
        #expect(screen.visible == ["abcde"])
        screen.feed(Data("f".utf8))
        #expect(screen.visible == ["abcde", "f"])
    }

    @Test("a carriage return overwrites the row from the left")
    func carriageReturn() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("12345\r999".utf8))
        #expect(screen.visible == ["99945"])
    }

    @Test("a shorter rewrite leaves the tail of the row it did not reach")
    func shorterRewrite() {
        // The difference from the line-based renderer, which has no columns to leave behind and
        // cuts the tail instead. A terminal keeps it: erasing is something a program asks for.
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("abcdef\rxy".utf8))
        #expect(screen.visible == ["xycdef"])
    }

    @Test("a backspace moves back a column so the next character overwrites")
    func backspace() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("ab\u{08}c".utf8))
        #expect(screen.visible == ["ac"])
    }

    @Test("a backspace at the left margin stays at it")
    func backspaceAtMargin() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("\u{08}\u{08}x".utf8))
        #expect(screen.visible == ["x"])
    }

    @Test("a tab goes to the next eight-column stop")
    func tabStops() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("ab\tc".utf8))
        #expect(screen.visible == ["ab      c"])
    }

    @Test("a bell is not a character")
    func bell() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("x\u{07}y".utf8))
        #expect(screen.visible == ["xy"])
    }

    @Test("a cursor position sequence puts text at an exact row and column")
    func cursorPosition() {
        var screen = TerminalScreen(columns: 10, rows: 4)
        screen.feed(Data("\u{1B}[3;5Hxy".utf8))
        #expect(screen.visible == ["", "", "    xy"])
    }

    @Test("the horizontal and vertical forms move one axis each")
    func cursorAxes() {
        var one = TerminalScreen(columns: 10, rows: 4)
        one.feed(Data("\u{1B}[3d\u{1B}[5Gx".utf8))
        #expect(one.visible == ["", "", "    x"])

        // `f` is the same request as `H`, and a missing column means the first.
        var other = TerminalScreen(columns: 10, rows: 4)
        other.feed(Data("\u{1B}[2fq".utf8))
        #expect(other.visible == ["", "q"])
    }

    @Test("relative movement is one-based and stops at the edges")
    func relativeMovement() {
        var screen = TerminalScreen(columns: 10, rows: 4)
        screen.feed(Data("\u{1B}[2B\u{1B}[3Cx".utf8))
        #expect(screen.visible == ["", "", "   x"])

        var edge = TerminalScreen(columns: 10, rows: 4)
        edge.feed(Data("\u{1B}[99A\u{1B}[99Dy".utf8))
        #expect(edge.visible == ["y"])
    }

    @Test("erasing from the cursor to the end of the line leaves what is before it")
    func eraseToEndOfLine() {
        var screen = TerminalScreen(columns: 10, rows: 4)
        screen.feed(Data("abcdefghij\u{1B}[5G\u{1B}[K".utf8))
        #expect(screen.visible == ["abcd"])
    }

    @Test("erasing from the start of the line to the cursor leaves what is after it")
    func eraseToStartOfLine() {
        var screen = TerminalScreen(columns: 10, rows: 4)
        screen.feed(Data("abcdefghij\u{1B}[5G\u{1B}[1K".utf8))
        #expect(screen.visible == ["     fghij"])
    }

    @Test("erasing the whole line empties it")
    func eraseWholeLine() {
        var screen = TerminalScreen(columns: 10, rows: 4)
        screen.feed(Data("abcdefghij\u{1B}[2K".utf8))
        #expect(screen.visible == [])
    }

    @Test("erasing to the end of the screen clears below the cursor too")
    func eraseToEndOfScreen() {
        var screen = TerminalScreen(columns: 5, rows: 3)
        screen.feed(Data("aa\r\nbb\r\ncc\u{1B}[H\u{1B}[J".utf8))
        #expect(screen.visible == [])
    }

    @Test("erasing to the start of the screen clears above the cursor too")
    func eraseToStartOfScreen() {
        var screen = TerminalScreen(columns: 5, rows: 3)
        screen.feed(Data("aa\r\nbb\r\ncc\u{1B}[2;2H\u{1B}[1J".utf8))
        #expect(screen.visible == ["", "", "cc"])
    }

    @Test("erasing the whole screen clears all of it")
    func eraseWholeScreen() {
        var screen = TerminalScreen(columns: 5, rows: 3)
        screen.feed(Data("aa\r\nbb\r\ncc\u{1B}[2J".utf8))
        #expect(screen.visible == [])
        #expect(screen.scrollback.isEmpty)
    }

    @Test("a line pushed off the top goes into the scrollback")
    func scrolling() {
        var screen = TerminalScreen(columns: 10, rows: 3)
        screen.feed(Data("one\r\ntwo\r\nthree\r\nfour".utf8))
        #expect(screen.scrollback == ["one"])
        #expect(screen.visible == ["two", "three", "four"])
    }

    @Test("the rendered lines are the scrollback and then the screen")
    func linesIncludeScrollback() {
        var screen = TerminalScreen(columns: 32, rows: 3)
        screen.feed(Data("zsh: command not found: foo\r\nwarning: deprecated\r\nok\r\nseen".utf8))
        #expect(screen.lines.map(\.text) == [
            "zsh: command not found: foo", "warning: deprecated", "ok", "seen",
        ])
        #expect(screen.lines.map(\.kind) == [.error, .warning, .plain, .plain])
    }

    @Test("an escape sequence leaves no characters behind")
    func escapeSequencesAreNotText() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        // Colour, a window title, a hidden cursor and an operating system command: none of it is
        // text, and the payload of the title is not either.
        screen.feed(Data("\u{1B}[1;32mgreen\u{1B}[0m\u{1B}]0;htop frame\u{07}\u{1B}[?25l\u{1B}[5n!".utf8))
        #expect(screen.visible == ["green!"])
        #expect(!screen.visible.joined().contains("\u{1B}"))
    }

    @Test("a charset designation does not print the byte that follows it")
    func charsetDesignation() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("\u{1B}(Bx".utf8))
        #expect(screen.visible == ["x"])
    }

    @Test("a parameter larger than the screen is clamped rather than trusted")
    func absurdParameters() {
        var screen = TerminalScreen(columns: 10, rows: 4)
        screen.feed(Data("\u{1B}[99999999;99999999Hx".utf8))
        // A position past the end lands in the corner instead of asking for a grid that is not
        // there, and the same is true of a number too long to be an `Int` at all.
        #expect(screen.visible == ["", "", "", "         x"])

        var overflowing = TerminalScreen(columns: 10, rows: 4)
        overflowing.feed(Data("\u{1B}[99999999999999999999;7Hy".utf8))
        #expect(overflowing.visible == ["", "", "", "      y"])

        // An erase whose mode is not one of the modes is not an erase.
        var erasing = TerminalScreen(columns: 10, rows: 4)
        erasing.feed(Data("abc\u{1B}[99999999J".utf8))
        #expect(erasing.visible == ["abc"])
    }

    @Test("a character split across two reads is one character, not two")
    func splitCharacter() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        let bytes = Array("héllo".utf8)
        // The half that arrived first waits for the other half rather than being printed as a
        // replacement character in the middle of a word.
        screen.feed(Data(bytes[0..<2]))
        #expect(screen.visible == ["h"])
        screen.feed(Data(bytes[2...]))
        #expect(screen.visible == ["héllo"])

        var emoji = TerminalScreen(columns: 20, rows: 4)
        let four = Array("a👍b".utf8)
        emoji.feed(Data(four[0..<2]))
        #expect(emoji.visible == ["a"])
        emoji.feed(Data(four[2...]))
        #expect(emoji.visible == ["a👍b"])
    }

    @Test("half an escape sequence prints nothing at all")
    func splitEscapeSequence() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        // A read can end anywhere, including in the middle of a sequence — neither half is text.
        screen.feed(Data("\u{1B}[2;".utf8))
        #expect(screen.visible == [])
        screen.feed(Data("3Hx".utf8))
        #expect(screen.visible == ["", "  x"])
    }

    @Test("the same bytes give the same screen however they are cut up")
    func replayIsStable() {
        // The caller re-processes its whole buffer from a fresh screen on every read, so a screen
        // built from one read and one built from many have to agree. That is only sound if the
        // bytes are the whole of the input and nothing accumulates outside them.
        let output = Data("\u{1B}[?1049h\u{1B}[Htop\u{1B}[1;1HZz\u{1B}[K".utf8)

        var whole = TerminalScreen(columns: 20, rows: 4)
        whole.feed(output)
        #expect(whole.visible == ["Zz"])

        var piecemeal = TerminalScreen(columns: 20, rows: 4)
        let bytes = Array(output)
        for start in stride(from: 0, to: bytes.count, by: 3) {
            piecemeal.feed(Data(bytes[start..<min(start + 3, bytes.count)]))
        }
        #expect(piecemeal.visible == whole.visible)
        #expect(piecemeal.lines == whole.lines)
    }

    @Test("a screen drawn the way htop draws one shows the last frame")
    func fullScreenProgram() {
        // The regression. A line-based renderer replays these bytes in order — the two frames run
        // into each other and the values that were overwritten are still on the row — so what is
        // asserted is not only that the text arrived but that it is in the right *place*.
        var screen = TerminalScreen(columns: 20, rows: 6)

        // Entering the alternate screen, then a frame the way htop draws one: cursor home, a
        // header, the cursor placed at a column to write a value, and a second value re-drawn over
        // the first with the rest of the row erased behind it.
        screen.feed(Data("\u{1B}[?1049h\u{1B}[HCPU\u{1B}[1;6H12%\u{1B}[2;1HMem\u{1B}[2;6H45%\u{1B}[3;1HTasks: 42".utf8))
        #expect(screen.visible == ["CPU  12%", "Mem  45%", "Tasks: 42"])

        // The refresh, with the values changed and a shorter one that has to erase the digit it
        // no longer covers.
        screen.feed(Data("\u{1B}[HCPU\u{1B}[1;6H9%\u{1B}[K\u{1B}[2;1HMem\u{1B}[2;6H62%\u{1B}[K\u{1B}[3;1HTasks: 43".utf8))
        #expect(screen.visible == ["CPU  9%", "Mem  62%", "Tasks: 43"])
        #expect(screen.visible.count == 3)

        // Leaving the alternate screen throws the picture away instead of smearing it into the
        // history, which is what makes htop vanish on exit the way it does in a terminal.
        screen.feed(Data("\u{1B}[?1049l".utf8))
        #expect(screen.visible == [])
        #expect(screen.scrollback == [])
    }

    @Test("the scrollback keeps the newest rows and drops the oldest")
    func scrollbackIsBounded() {
        // Bounded here rather than at the byte buffer the caller trims: the cells are this side's copy.
        var screen = TerminalScreen(columns: 20, rows: 4)
        for index in 0..<5_000 {
            screen.feed(Data("line \(index)\r\n".utf8))
        }

        let kept = screen.scrollback
        let bounded = kept.count < 3_000
        let oldest = kept.contains { $0.hasPrefix("line 0") }
        // The newest rows are on the screen rather than in the scrollback, so what is checked is
        // the row just above it: the most recent one that has scrolled off.
        let lastKept = kept.last ?? ""
        let recent = lastKept.hasPrefix("line 49")

        #expect(bounded)
        #expect(!oldest)
        #expect(recent)
    }

    @Test("a screen fed in pieces styles the same as one fed at once")
    func styledMatchesAScreenBuiltInOneGo() {
        // The kept copy of the styled rows has to be the same answer as re-styling them.
        let bytes = Data((0..<3_000).map { "row \($0)\r\n" }.joined().utf8)

        var piecemeal = TerminalScreen(columns: 20, rows: 6)
        let raw = Array(bytes)
        for start in stride(from: 0, to: raw.count, by: 97) {
            piecemeal.feed(Data(raw[start..<min(start + 97, raw.count)]))
        }

        var whole = TerminalScreen(columns: 20, rows: 6)
        whole.feed(bytes)

        let stylesAgree = piecemeal.styled == whole.styled
        let textAgrees = piecemeal.visible == whole.visible

        #expect(stylesAgree)
        #expect(textAgrees)
    }
}
