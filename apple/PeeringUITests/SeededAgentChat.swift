//
//  SeededAgentChat.swift
//  PeeringUITests
//
//  Launches the app with a pretend Mac and a seeded agent chat, and walks to it, so a chat can be
//  driven with no host. The seeds are DEBUG-only (`AgentSeed+Scenarios.swift`).
//

import XCTest

enum SeededAgentChat {
    /// `plan` is a `RelayPlan` raw value (`free`, `relay`, `pro`).
    @MainActor
    static func launch(scenario: String, plan: String = "pro") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-Peering.hasSeenWelcome", "1", "-Peering.hasSeenTourConnect", "1",
            "-Peering.hasSeenTourServers", "1", "-Peering.hasSeenTourShell", "1",
            "-Peering.hasSeenTourTerminal", "1", "-Peering.hasSeenTourScreen", "1",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-Peering.seedAgentChat", "1", "-Peering.seedFakeMac", "1",
            "-Peering.seedAgentScenario", scenario,
            "-Peering.developerPlanOverride", plan,
            "-Peering.resumeWhenReachable", "0", "-Peering.lastHostID", "", "-Peering.lastHostName", "",
        ]
        app.launch()
        return app
    }

    /// The Agents page of the terminals hub, where chats are listed.
    @MainActor
    static func openAgentsHub(_ app: XCUIApplication) {
        let terminals = app.buttons["Open Mac terminals"]
        XCTAssertTrue(terminals.waitForExistence(timeout: 15), "The pretend Mac never reached its session screen:\n\(app.debugDescription)")
        terminals.tap()
        // The tab's label carries the open count ("Agents, 1"), so match its start.
        let agents = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Agents'")).firstMatch
        if agents.waitForExistence(timeout: 3) { agents.tap() }
    }

    /// The card of a seeded chat, found by the folder its title names.
    @MainActor
    static func chatCard(_ app: XCUIApplication, folder: String) -> XCUIElement {
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", folder)).firstMatch
    }

    @MainActor
    static func openChat(_ app: XCUIApplication, folder: String = "orders-service") {
        openAgentsHub(app)
        let card = chatCard(app, folder: folder)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "The seeded chat is not listed:\n\(app.debugDescription)")
        card.tap()
    }
}
