//
//  AgentChatLimitFlowTests.swift
//  MacCastUITests
//
//  The free plan allows three agent chats at once: a fourth shows the paywall instead of starting,
//  and a paid plan starts it.
//

import XCTest

final class AgentChatLimitFlowTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// "New chat here" on an existing card is the shortest way to start another chat in the same folder.
    @MainActor
    private func startAnotherChat(_ app: XCUIApplication) {
        SeededAgentChat.openAgentsHub(app)
        let card = SeededAgentChat.chatCard(app, folder: "api")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "The seeded chats are not listed:\n\(app.debugDescription)")
        XCTAssertTrue(
            app.staticTexts["3 open on your Mac"].exists,
            "Three seeded chats should count as three open."
        )
        card.press(forDuration: 1)
        let startHere = app.buttons["New chat here"]
        XCTAssertTrue(startHere.waitForExistence(timeout: 5), "The card's menu should offer a new chat.")
        startHere.tap()
    }

    @MainActor
    func testAFourthChatOnTheFreePlanShowsThePaywall() throws {
        let app = SeededAgentChat.launch(scenario: "threeLive", plan: "free")
        startAnotherChat(app)

        XCTAssertTrue(
            app.staticTexts["Unlock More than three agents at once"].waitForExistence(timeout: 5),
            "The free plan's fourth chat should open the paywall:\n\(app.debugDescription)"
        )
        XCTAssertFalse(
            SeededAgentChat.chatCard(app, folder: "new chat").exists,
            "The fourth chat should not have started."
        )
    }

    @MainActor
    func testAFourthChatOnAPaidPlanStarts() throws {
        let app = SeededAgentChat.launch(scenario: "threeLive", plan: "relay")
        startAnotherChat(app)

        XCTAssertTrue(
            SeededAgentChat.chatCard(app, folder: "new chat").waitForExistence(timeout: 5),
            "A paid plan should start the fourth chat:\n\(app.debugDescription)"
        )
        XCTAssertFalse(
            app.staticTexts["Unlock More than three agents at once"].exists,
            "A paid plan should not meet the paywall."
        )
    }
}
