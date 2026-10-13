//
//  AgentApprovalFlowTests.swift
//  MacCastUITests
//
//  The sheet an agent's ask opens: a multi-question ask walks one question at a time, and a command
//  approval shows the command itself with the CLI's reason beneath it.
//

import XCTest

final class AgentApprovalFlowTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func option(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons["approval.option.\(label)"]
    }

    @MainActor
    func testThreeQuestionsAreAnsweredOneAtATime() throws {
        let app = SeededAgentChat.launch(scenario: "questionAsk")
        SeededAgentChat.openChat(app)

        XCTAssertTrue(app.staticTexts["Question 1 of 3"].waitForExistence(timeout: 10), "The ask should open on its first question.")
        XCTAssertTrue(option("Postgres", in: app).exists)
        XCTAssertFalse(app.buttons["approval.back"].exists, "The first question has nothing to go back to.")

        option("Postgres", in: app).tap()
        XCTAssertTrue(app.staticTexts["Question 2 of 3"].waitForExistence(timeout: 3), "Choosing an option should move to the next question.")
        XCTAssertTrue(option("OAuth", in: app).exists)

        option("OAuth", in: app).tap()
        XCTAssertTrue(app.staticTexts["Question 3 of 3"].waitForExistence(timeout: 3))

        app.buttons["approval.back"].tap()
        XCTAssertTrue(app.staticTexts["Question 2 of 3"].waitForExistence(timeout: 3), "Back should return to the previous question.")

        option("API key", in: app).tap()
        XCTAssertTrue(app.staticTexts["Question 3 of 3"].waitForExistence(timeout: 3))
        option("Fly.io", in: app).tap()

        XCTAssertTrue(
            app.staticTexts["Answered: Postgres, API key, Fly.io"].waitForExistence(timeout: 5),
            "The last pick should send every answer, with the one changed by Back:\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            app.staticTexts["Question 3 of 3"].waitForNonExistence(timeout: 5),
            "The sheet should close after the last pick."
        )
    }

    @MainActor
    func testACommandApprovalShowsTheCommandAndThenTheReason() throws {
        let app = SeededAgentChat.launch(scenario: "bashAsk")
        SeededAgentChat.openChat(app)

        let command = app.staticTexts["approval.command"]
        XCTAssertTrue(command.waitForExistence(timeout: 10), "The approval should open.")
        XCTAssertEqual(command.label, "npm test --workspace orders", "The main block should be the command itself, not the reason.")

        let reason = app.staticTexts["approval.reason"]
        XCTAssertTrue(reason.exists, "The CLI's reason should sit beneath the command.")
        XCTAssertEqual(reason.label, "Runs the project's test suite, which writes to the build folder.")
        XCTAssertLessThan(command.frame.minY, reason.frame.minY, "The reason is a caption under the command.")
    }
}
