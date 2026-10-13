//
//  AgentChatScreenTests.swift
//  PeeringUITests
//
//  What an open agent chat shows: the model picker's names.
//

import XCTest

final class AgentChatScreenTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTheModelPickerListsExactModelNames() throws {
        let app = SeededAgentChat.launch(scenario: "empty")
        SeededAgentChat.openChat(app)

        let picker = app.buttons["chat.modelMenu"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "The chat should offer a model picker:\n\(app.debugDescription)")
        picker.tap()

        for name in ["fable-5.1", "opus-5.5", "sonnet-5.5", "haiku-4.5"] {
            XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 3), "The picker should list \(name).")
        }
        for alias in ["sonnet", "opus", "haiku", "fable"] {
            XCTAssertFalse(app.buttons[alias].exists, "The picker should not list the bare alias \(alias).")
        }
    }
}
