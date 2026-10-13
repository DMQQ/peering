//
//  PaywallShotTests.swift
//  PeeringUITests
//
//  TEMPORARY. A screenshot run for the paywall rework: the cards, the period picker and the footer
//  are all behind a tap, and a simulator driven by `simctl` alone cannot make one. Delete this file
//  once the screens have been looked at.
//

import XCTest

final class PaywallShotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPaywallScreens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-Peering.hasSeenWelcome", "1"]
        app.launch()

        app.tabBars.buttons["Settings"].tap()

        let upgrade = app.buttons["Upgrade to Pro"]
        for _ in 0..<10 where !upgrade.exists {
            app.swipeUp()
        }
        XCTAssertTrue(
            upgrade.waitForExistence(timeout: 5),
            "the Settings row was never reached:\n\(app.debugDescription)"
        )
        upgrade.tap()

        XCTAssertTrue(
            app.buttons["See everything Peering does"].waitForExistence(timeout: 10),
            "the paywall never opened:\n\(app.debugDescription)"
        )
        capture(app, "1-paywall-top")

        app.swipeUp()
        capture(app, "2-paywall-middle")

        app.swipeUp()
        capture(app, "3-paywall-bottom")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
