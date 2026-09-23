import XCTest
@testable import MacCastKit

/// Which commands want the terminal drawn small.
///
/// The rule is about what a program does with a terminal, not about one program, so these hold the
/// line where it is: what is being run is the first word that is not a wrapper, and the words after
/// it are arguments rather than programs.
final class TerminalProgramTests: XCTestCase {
    func testAFullScreenProgramAsksForSmallText() {
        XCTAssertTrue(TerminalProgram.prefersSmallText("claude"))
        XCTAssertTrue(TerminalProgram.prefersSmallText("vim notes.txt"))
        XCTAssertTrue(TerminalProgram.prefersSmallText("  htop  "))
    }

    /// A program is not a name that happens to appear in a command line.
    func testTheArgumentsAreNotTheProgram() {
        XCTAssertFalse(TerminalProgram.prefersSmallText("grep vim ~/.zshrc"))
        XCTAssertFalse(TerminalProgram.prefersSmallText("git commit -m \"claude\""))
        XCTAssertFalse(TerminalProgram.prefersSmallText("ls -la"))
        XCTAssertFalse(TerminalProgram.prefersSmallText(""))
    }

    /// What runs it, rather than the program: a path, a wrapper, or a variable set for it.
    func testTheProgramIsFoundThroughWrappersAndPaths() {
        XCTAssertTrue(TerminalProgram.prefersSmallText("/opt/homebrew/bin/claude"))
        XCTAssertTrue(TerminalProgram.prefersSmallText("sudo vim /etc/hosts"))
        XCTAssertTrue(TerminalProgram.prefersSmallText("FOO=1 claude --continue"))
    }
}
