//
//  TourFlowTests.swift
//  MacCastUITests
//
//  Walks the first-run tips: the Connect screen's tour runs to its end, the Servers screen's is
//  skipped, neither comes back after a relaunch, the Settings row puts them all back, and a shell
//  on a server hands its own tour over to the terminal's.
//
//  It exists because the whole of this feature is invisible to everything below it. What the tips
//  are made of is a preference key and two rectangles, and every unit test of those passes on a
//  build where the overlay is never mounted at all — which is exactly what happened: the tips ran
//  on no screen for a while because the modifier was applied to the wrong view, and nothing in
//  `MacCastKitTests` could tell. What is worth asserting is not that the app compiles. It is that
//  a screen nobody has seen before shows a card, that the card's Next button moves it on, and that
//  a screen that has been answered goes quiet — including after the app has been launched again,
//  which is the half of "once" that a single launch cannot show.
//
//  **Run it against a wiped container**, for the reason the SSH flow test gives: the tips are
//  remembered in `UserDefaults`, and a second run starts with them already answered:
//
//      xcrun simctl uninstall 825ECC2B-F0D1-439A-9F1B-AD942DFE178F pl.dmq.peering
//
//  The scheme's `TestAction` also has no `TestableReference` for `MacCastUITests`, so `xcodebuild
//  test` refuses until one is added to `MacCast.xcscheme` — a temporary edit, and the same one the
//  other UI tests in this target document.
//
//  The welcome flow is skipped with a launch argument rather than by tapping through it. That is
//  the argument domain, which outranks the app's own defaults for the length of the launch and
//  writes nothing down, so it cannot be mistaken for a tour flag being set.
//

import XCTest

final class TourFlowTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The tip that is on screen, read by the counter on its card.
    ///
    /// By the counter rather than by the sentence, because the step's words also appear on the
    /// dimmed layer behind it — the whole screen is one accessibility element while a tip is up —
    /// and a query matching both is a query that fails on a screen where only one of them exists.
    @MainActor
    private func tip(_ number: Int, of count: Int, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["\(number) of \(count)"]
    }

    /// A tab on the system's bar, named through `tabBars` for the reason the FAQ test gives: the
    /// word "Servers" is also the leading item on the shell screen, which is a button too.
    @MainActor
    private func tab(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons[name]
    }

    /// The Connect screen's tips, then the Servers screen's, then both again on purpose.
    @MainActor
    func testTipsRunOnceAndTheSettingsRowBringsThemBack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-Peering.hasSeenWelcome", "1"]
        app.launch()

        // MARK: The Connect screen

        // Three steps on a fresh install: the card that explains the first pairing, the list of
        // what is on this network, and the way in for a Mac that is not on it. The fourth step,
        // the trusted Macs, is below the fold on this phone and is dropped rather than drawn.
        XCTAssertTrue(
            tip(1, of: 3, in: app).waitForExistence(timeout: 10),
            "the Connect screen's tips never appeared:\n\(app.debugDescription)"
        )
        capture(app, "1-connect-first-step")

        app.buttons["Next"].tap()
        XCTAssertTrue(tip(2, of: 3, in: app).waitForExistence(timeout: 4), "Next did not move on")

        app.buttons["Next"].tap()
        XCTAssertTrue(tip(3, of: 3, in: app).waitForExistence(timeout: 4), "Next did not move on")
        capture(app, "2-connect-last-step")

        app.buttons["Done"].tap()
        XCTAssertTrue(
            tip(3, of: 3, in: app).waitForNonExistence(timeout: 4),
            "the last step did not put the tips away"
        )
        capture(app, "3-connect-answered")

        // MARK: The Servers screen, and the other exit

        tab("Servers", in: app).tap()
        XCTAssertTrue(
            tip(1, of: 2, in: app).waitForExistence(timeout: 10),
            "the Servers screen's tips never appeared:\n\(app.debugDescription)"
        )
        capture(app, "4-servers-first-step")

        app.buttons["Next"].tap()
        XCTAssertTrue(tip(2, of: 2, in: app).waitForExistence(timeout: 4), "Next did not move on")
        capture(app, "5-servers-last-step")

        // Skipped rather than finished, which is the exit that has to write the flag just as
        // firmly: it is the one somebody in the middle of something uses.
        app.buttons["Skip"].tap()
        XCTAssertTrue(
            tip(2, of: 2, in: app).waitForNonExistence(timeout: 4),
            "Skip did not put the tips away"
        )

        // MARK: The tips stay answered across a launch

        app.terminate()
        app.launch()

        tab("Servers", in: app).tap()
        XCTAssertFalse(
            tip(1, of: 2, in: app).waitForExistence(timeout: 3),
            "the Servers screen's tips came back after a relaunch"
        )
        tab("Connect", in: app).tap()
        XCTAssertFalse(
            tip(1, of: 3, in: app).waitForExistence(timeout: 3),
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
            tip(1, of: 3, in: app).waitForExistence(timeout: 10),
            "the tips were not owed again after the Settings row was tapped"
        )
        capture(app, "7-connect-owed-again")
    }

    /// A shell's own tips, and the terminal's following them.
    ///
    /// One screen owes two tours, and the second is not a repeat of the first: the strip and the
    /// switch between the shell and the server's files are about the *connection*, and the log, the
    /// keys and the command line are about the terminal. The hand-over is the thing worth seeing,
    /// because it is the part of the mechanism no single-screenshot check can show.
    @MainActor
    func testAShellsTipsHandOverToTheTerminals() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-Peering.hasSeenWelcome", "1"]
        app.launch()

        // Whatever the previous test left behind, this one starts owing every tip: the row is the
        // same one a user presses to see them again, and using it here keeps the two tests
        // independent of the order they run in.
        tab("Settings", in: app).tap()
        let row = app.buttons["Show tips again"]
        for _ in 0..<10 where !row.exists {
            app.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the Settings row was never reached")
        row.tap()

        // MARK: A server, by hand

        tab("Servers", in: app).tap()

        // The Servers tab owes its own tips now that the row above has been pressed, and a tip is
        // a dimmed screen with one control lit: "Add a server" is behind it and the tap would land
        // on the dim. Answered here, which is also the only way to reach the button underneath.
        XCTAssertTrue(tip(1, of: 2, in: app).waitForExistence(timeout: 10),
                      "the Servers screen's tips never appeared")
        app.buttons["Skip"].tap()
        XCTAssertTrue(tip(1, of: 2, in: app).waitForNonExistence(timeout: 4), "Skip did nothing")

        app.buttons["Add a server"].tap()

        // The simulator's own loopback, where nothing is listening: the shell is refused within a
        // second, and a shell that failed still has a strip, a toggle and a terminal.
        let host = app.textFields["box.example.com"]
        XCTAssertTrue(host.waitForExistence(timeout: 5), "the Host field never appeared")
        host.tap()
        host.typeText("127.0.0.1")

        let user = app.textFields["root"]
        user.tap()
        user.typeText("deploy")

        app.buttons["Add server"].tap()

        // `firstMatch`, because a container that has not been wiped has the servers of every
        // previous run in this list, and the tap only needs one of them.
        let saved = app.staticTexts["127.0.0.1"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "the server was not saved")

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
            tip(1, of: 2, in: app).waitForExistence(timeout: 15),
            "the shell screen's tips never appeared:\n\(app.debugDescription)"
        )
        capture(app, "8-shell-tabs")

        app.buttons["Next"].tap()
        XCTAssertTrue(tip(2, of: 2, in: app).waitForExistence(timeout: 4), "Next did not move on")
        capture(app, "9-shell-mode")

        // MARK: The terminal, which this screen owes as well

        app.buttons["Done"].tap()
        XCTAssertTrue(
            tip(1, of: 3, in: app).waitForExistence(timeout: 6),
            "the terminal's tips did not follow the shell's:\n\(app.debugDescription)"
        )
        capture(app, "10-terminal-log")

        app.buttons["Next"].tap()
        XCTAssertTrue(tip(2, of: 3, in: app).waitForExistence(timeout: 4), "Next did not move on")
        capture(app, "11-terminal-deck")

        app.buttons["Next"].tap()
        XCTAssertTrue(tip(3, of: 3, in: app).waitForExistence(timeout: 4), "Next did not move on")
        capture(app, "12-terminal-input")

        app.buttons["Done"].tap()
        XCTAssertTrue(
            tip(3, of: 3, in: app).waitForNonExistence(timeout: 4),
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
