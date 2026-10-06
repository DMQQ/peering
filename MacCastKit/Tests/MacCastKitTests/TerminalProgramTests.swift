import XCTest
@testable import MacCastKit

/// Which commands want the terminal drawn small: the first non-wrapper word is the program.
final class TerminalProgramTests: XCTestCase {
    func testAFullScreenProgramAsksForSmallText() {
        XCTAssertTrue(TerminalProgram.prefersSmallText("claude"))
        for agent in ["codex", "opencode", "hermes", "gemini"] {
            XCTAssertTrue(TerminalProgram.prefersSmallText(agent), agent)
        }
        XCTAssertTrue(TerminalProgram.prefersSmallText("vim notes.txt"))
        XCTAssertTrue(TerminalProgram.prefersSmallText("  htop  "))
    }

    func testTheArgumentsAreNotTheProgram() {
        XCTAssertFalse(TerminalProgram.prefersSmallText("grep vim ~/.zshrc"))
        XCTAssertFalse(TerminalProgram.prefersSmallText("git commit -m \"claude\""))
        XCTAssertFalse(TerminalProgram.prefersSmallText("ls -la"))
        XCTAssertFalse(TerminalProgram.prefersSmallText(""))
    }

    func testTheProgramIsFoundThroughWrappersAndPaths() {
        XCTAssertTrue(TerminalProgram.prefersSmallText("/opt/homebrew/bin/claude"))
        XCTAssertTrue(TerminalProgram.prefersSmallText("sudo vim /etc/hosts"))
        XCTAssertTrue(TerminalProgram.prefersSmallText("FOO=1 claude --continue"))
    }
}
