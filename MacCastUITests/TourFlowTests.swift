//
//  TourFlowTests.swift
//  MacCastUITests
//
// Walks the first-run tips: the Connect screen's tour runs to its end, the Servers screen's is skipped, neither returns after a relaunch, the Settings row restores them, and a shell hands its tour to the terminal's.
// **Run it against a wiped container**: the tips are remembered in `UserDefaults`, so a second run starts answered:
//
//      xcrun simctl uninstall 825ECC2B-F0D1-439A-9F1B-AD942DFE178F pl.dmq.peering
//
// The scheme has no `TestableReference` for `MacCastUITests`, so `xcodebuild test` refuses until one is added to `MacCast.xcscheme` (temporary edit).
//
// The welcome flow is skipped with a launch argument (argument domain), which writes nothing down.

import XCTest

final class TourFlowTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The tip on screen, found by a phrase from its step and not the counter, whose total varies with the room the screen has.
    /// Matched inside `staticTexts`: a step's words are also the label of the dimmed layer behind it.
    @MainActor
    private func tip(_ phrase: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", phrase))
            .firstMatch
    }

    private let connectFirstStep = "This card has the Mac download"
    private let connectSecondStep = "appears here while Peering is"
    private let connectThirdStep = "type or scan the device ID"
    private let serversFirstStep = "Machines you added by hand. Tap one"
    private let serversSecondStep = "A hostname and a key or a password"
    private let shellFirstStep = "Each shell you open gets a tab"
    private let shellSecondStep = "Everything the server prints"
    private let terminalFirstStep = "Control keys and the commands you save"
    private let terminalSecondStep = "Type here and press Return"

    /// Named through `tabBars`: "Servers" is also the leading button on the shell screen.
    @MainActor
    private func tab(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons[name]
    }

    /// Puts every tip back through the Settings row.
    ///
    /// Both tests open with this: they share a container and the shell walk answers the Servers tips, so a later test would find them taught.
    @MainActor
    private func resetTips(in app: XCUIApplication) {
        tab("Settings", in: app).tap()
        let row = app.buttons["Show tips again"]
        for _ in 0..<10 where !row.exists {
            app.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the Settings row was never reached")
        row.tap()
    }

    @MainActor
    func testTipsRunOnceAndTheSettingsRowBringsThemBack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-Peering.hasSeenWelcome", "1"]
        app.launch()

        resetTips(in: app)
        tab("Connect", in: app).tap()

        // MARK: The Connect screen

        XCTAssertTrue(
            tip(connectFirstStep, in: app).waitForExistence(timeout: 10),
            "the Connect screen's tips never appeared:\n\(app.debugDescription)"
        )
        capture(app, "1-connect-first-step")

        app.buttons["Next"].tap()
        XCTAssertTrue(
            tip(connectSecondStep, in: app).waitForExistence(timeout: 4),
            "Next did not move on"
        )

        // Tap `Next` until it says `Done`, so the step count does not matter.
        for _ in 0..<6 where app.buttons["Next"].exists {
            app.buttons["Next"].tap()
        }
        XCTAssertTrue(
            app.buttons["Done"].waitForExistence(timeout: 4),
            "the Connect screen's tips never reached a last step"
        )
        capture(app, "2-connect-last-step")

        app.buttons["Done"].tap()
        XCTAssertTrue(
            app.buttons["Skip"].waitForNonExistence(timeout: 4),
            "the last step did not put the tips away"
        )
        capture(app, "3-connect-answered")

        // MARK: The Servers screen, and the other exit

        tab("Servers", in: app).tap()
        XCTAssertTrue(
            tip(serversFirstStep, in: app).waitForExistence(timeout: 10),
            "the Servers screen's tips never appeared:\n\(app.debugDescription)"
        )
        capture(app, "4-servers-first-step")

        app.buttons["Next"].tap()
        XCTAssertTrue(
            tip(serversSecondStep, in: app).waitForExistence(timeout: 4),
            "Next did not move on"
        )
        capture(app, "5-servers-last-step")

        // Skipped rather than finished: the exit that must write the flag just as firmly.
        app.buttons["Skip"].tap()
        XCTAssertTrue(
            tip(serversSecondStep, in: app).waitForNonExistence(timeout: 4),
            "Skip did not put the tips away"
        )

        // MARK: The tips stay answered across a launch

        app.terminate()
        app.launch()

        tab("Servers", in: app).tap()
        XCTAssertFalse(
            tip(serversFirstStep, in: app).waitForExistence(timeout: 3),
            "the Servers screen's tips came back after a relaunch"
        )
        tab("Connect", in: app).tap()
        XCTAssertFalse(
            tip(connectFirstStep, in: app).waitForExistence(timeout: 3),
            "the Connect screen's tips came back after a relaunch"
        )

        // MARK: And back again, from Settings

        tab("Settings", in: app).tap()
        let row = app.buttons["Show tips again"]
        for _ in 0..<10 where !row.exists {
            app.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the Settings row was never reached")
        capture(app, "6-settings-row")
        row.tap()

        tab("Connect", in: app).tap()
        XCTAssertTrue(
            tip(connectFirstStep, in: app).waitForExistence(timeout: 10),
            "the tips were not owed again after the Settings row was tapped"
        )
        capture(app, "7-connect-owed-again")
    }

    @MainActor
    func testAShellsTipsHandOverToTheTerminals() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-Peering.hasSeenWelcome", "1"]
        app.launch()

        resetTips(in: app)

        // MARK: A server, by hand

        tab("Servers", in: app).tap()

        // A tip dims the screen, so "Add a server" is unreachable until the Servers tips are answered.
        XCTAssertTrue(tip(serversFirstStep, in: app).waitForExistence(timeout: 10),
                      "the Servers screen's tips never appeared")
        app.buttons["Skip"].tap()
        XCTAssertTrue(
            tip(serversFirstStep, in: app).waitForNonExistence(timeout: 4),
            "Skip did nothing"
        )

        app.buttons["Add a server"].tap()

        // Nothing listens on loopback, so the shell is refused; a failed shell still has a strip, a toggle and a terminal.
        let host = app.textFields["box.example.com"]
        XCTAssertTrue(host.waitForExistence(timeout: 5), "the Host field never appeared")
        host.tap()
        host.typeText("127.0.0.1")

        let user = app.textFields["root"]
        user.tap()
        user.typeText("deploy")

        app.buttons["Add server"].tap()

        // An unwiped container lists earlier runs' servers, some of them locked, and the newest is last.
        XCTAssertTrue(app.staticTexts["127.0.0.1"].firstMatch.waitForExistence(timeout: 5), "the server was not saved")
        let saved = app.staticTexts.matching(NSPredicate(format: "label == %@", "127.0.0.1")).allElementsBoundByIndex.last ?? app.staticTexts["127.0.0.1"].firstMatch

        // MARK: The shell screen

        saved.tap()

        let passwordField = app.textFields["Password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 8), "the sign-in sheet never appeared")
        passwordField.tap()
        passwordField.typeText("hunter2")

        // Scoped to the sheet, because "Connect" is also the name of a tab.
        let inSheet = app.sheets.buttons["Connect"].firstMatch
        let connect = inSheet.exists ? inSheet : app.navigationBars.buttons["Connect"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "the sign-in sheet had nothing to tap")
        connect.tap()

        XCTAssertTrue(
            tip(shellFirstStep, in: app).waitForExistence(timeout: 15),
            "the shell screen's tips never appeared:\n\(app.debugDescription)"
        )
        capture(app, "8-shell-tabs")

        app.buttons["Next"].tap()
        XCTAssertTrue(
            tip(shellSecondStep, in: app).waitForExistence(timeout: 4),
            "Next did not move on"
        )
        capture(app, "9-shell-output")

        // MARK: The terminal, which this screen owes as well

        app.buttons["Done"].tap()
        XCTAssertTrue(
            tip(terminalFirstStep, in: app).waitForExistence(timeout: 6),
            "the terminal's tips did not follow the shell's:\n\(app.debugDescription)"
        )
        capture(app, "10-terminal-deck")

        app.buttons["Next"].tap()
        XCTAssertTrue(
            tip(terminalSecondStep, in: app).waitForExistence(timeout: 4),
            "Next did not move on"
        )
        capture(app, "11-terminal-input")

        app.buttons["Done"].tap()
        XCTAssertTrue(
            tip(terminalSecondStep, in: app).waitForNonExistence(timeout: 4),
            "the last step did not put the tips away"
        )
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
