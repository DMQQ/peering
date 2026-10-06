import XCTest

@testable import MacCastKit

final class AgentMarkdownTests: XCTestCase {
    func testParagraphsAndCode() {
        let text = """
        Here is the plan.

        ```swift
        let a = 1
        let b = 2
        ```

        That is all.
        """
        XCTAssertEqual(AgentMarkdown.split(text), [
            .paragraph("Here is the plan."),
            .code("let a = 1\nlet b = 2"),
            .paragraph("That is all."),
        ])
    }

    func testBullets() {
        let text = """
        Steps:
        - first
        - second
        * third
        done.
        """
        XCTAssertEqual(AgentMarkdown.split(text), [
            .paragraph("Steps:"),
            .bullets(["first", "second", "third"]),
            .paragraph("done."),
        ])
    }

    func testHeadings() {
        let text = """
        # Title
        Some words.

        ## Section
        ### Small
        """
        XCTAssertEqual(AgentMarkdown.split(text), [
            .heading(level: 1, text: "Title"),
            .paragraph("Some words."),
            .heading(level: 2, text: "Section"),
            .heading(level: 3, text: "Small"),
        ])
    }

    /// Seven hashes is not a heading, and neither is a hash with no space: both are lines a
    /// shell transcript produces and should read as typed.
    func testHashesThatAreNotHeadings() {
        XCTAssertEqual(AgentMarkdown.split("####### seven hashes"), [.paragraph("####### seven hashes")])
        XCTAssertEqual(AgentMarkdown.split("#nospace"), [.paragraph("#nospace")])
    }

    /// The stream caught mid-block: an unclosed fence is code until the closing line arrives.
    func testUnclosedFenceIsCode() {
        XCTAssertEqual(AgentMarkdown.split("```\nlet a = 1"), [.code("let a = 1")])
    }

    /// Inline markdown stays in the paragraph, for the text view to render.
    func testInlineMarkdownIsLeftAlone() {
        XCTAssertEqual(AgentMarkdown.split("Use `npm test` **now**."), [.paragraph("Use `npm test` **now**.")])
    }

    func testEmptyText() {
        XCTAssertEqual(AgentMarkdown.split(""), [])
        XCTAssertEqual(AgentMarkdown.split("\n\n"), [])
    }
}
