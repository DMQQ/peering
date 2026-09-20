//
//  TabBarChecks.swift
//  MacCastUITests
//
//  TEMPORARY. Walks to the shell screen to check that the custom bar goes away there, the way the
//  system tab bar did. Needs the server the SSH flow test leaves behind: run that first, with the
//  container wiped. Delete this file.
//

import XCTest

final class TabBarChecks: XCTestCase {

    @MainActor
    func testShellScreenHidesTheBar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-Peering.hasSeenWelcome", "1"]
        app.launch()

        app.scrollViews["RootTabBar"].buttons["Servers"].tap()

        let row = app.staticTexts["127.0.0.1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the saved server was not listed")
        row.tap()

        // The pad the earlier run left on this server.
        XCTAssertTrue(app.staticTexts["Locked"].waitForExistence(timeout: 5), "no lock sheet")
        for character in "481620" { app.buttons[String(character)].tap() }

        let passwordField = app.textFields["Password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 8), "no sign-in sheet")
        passwordField.tap()
        passwordField.typeText("hunter2")

        let inSheet = app.sheets.buttons["Connect"].firstMatch
        let connect = inSheet.exists ? inSheet : app.navigationBars.buttons["Connect"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "nothing to sign in with")
        connect.tap()

        // The shell screen, which is the tab's own root rather than something pushed.
        Thread.sleep(forTimeInterval: 8)
        capture(app, "1-shell-screen")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
