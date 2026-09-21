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
//  build where the overlay is never mounted at all, which is exactly what happened: the tips ran
//  on no screen for a while because the modifier was applied to the wrong view, and nothing in
//  `MacCastKitTests` could tell. What is worth asserting is not that the app compiles. It is that
//  a screen nobody has seen before shows a card, that the card's Next button moves it on, and that
//  a screen that has been answered goes quiet, including after the app has been launched again,
//  which is the half of "once" that a single launch cannot show.
//
//  **Run it against a wiped container**, for the reason the SSH flow test gives: the tips are
//  remembered in `UserDefaults`, and a second run starts with them already answered:
//
//      xcrun simctl uninstall 825ECC2B-F0D1-439A-9F1B-AD942DFE178F pl.dmq.peering
//
//  The scheme's `TestAction` also has no `TestableReference` for `MacCastUITests`, so `xcodebuild
//  test` refuses until one is added to `MacCast.xcscheme`. A temporary edit, and the same one the
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

    /// The tip that is on screen, found by a phrase from the step it is showing.
    ///
    /// **By the sentence and not by the counter on the card.** How many steps a tour has depends on
    /// what the screen has room for: the Connect screen's last step is a card that is only on the
    /// screen when the list above it has not pushed it past the fold, and the same build answers
    /// "1 of 3" on one run and "1 of 4" on the next as the list finds a Mac and grows a row. The
    /// counter is the right thing to *read* and the wrong thing to assert on.
    ///
    /// Matched inside `staticTexts` rather than anywhere in the app, because a step's words are
    /// also the accessibility label of the dimmed layer behind it (the whole screen is one element
    /// while a tip is up), and a query that matches both is a query that fails.
    @MainActor
    private func tip(_ phrase: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", phrase))
            .firstMatch
    }

    /// The first step of the Connect screen's tour, by a phrase only that step's sentence has.
    private let connectFirstStep = "This card has the Mac download"
    private let connectSecondStep = "appears here while Peering is"
    private let connectThirdStep = "type or scan the device ID"
    private let serversFirstStep = "Machines you added by hand. Tap one"
    private let serversSecondStep = "A hostname and a key or a password"
    private let shellFirstStep = "Each shell you open gets a tab"
    private let shellSecondStep = "Everything the server prints"
    private let terminalFirstStep = "Control keys and the commands you save"
    private let terminalSecondStep = "Type here and press Return"

    /// A tab on the system's bar, named through `tabBars` for the reason the FAQ test gives: the
    /// word "Servers" is also the leading item on the shell screen, which is a button too.
    @MainActor
    private func tab(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons[name]
    }

    /// Puts every tip back, through the row a user would press to see them again.
    ///
    /// **Both tests open with this, and it is not belt and braces.** The two of them share one
    /// container and one set of five flags, and XCTest runs test methods in alphabetical order: the
    /// shell walk answers the Servers screen's tips on its way past, so a walk that ran second
    /// would find a screen that had already been taught. Starting from the row makes each test
    /// independent of the other, and it exercises the row into the bargain.
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

    /// The Connect screen's tips, then the Servers screen's, then both again on purpose.
    @MainActor
    func testTipsRunOnceAndTheSettingsRowBringsThemBack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-Peering.hasSeenWelcome", "1"]
        app.launch()

        resetTips(in: app)
        tab("Connect", in: app).tap()

        // MARK: The Connect screen

        // Four steps written and three or four shown, depending on whether the trusted Macs are
        // above the fold: the card that explains the first pairing, the list of what is on this
        // network, the way in for a Mac that is not on it, and the Macs already paired.
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

        // On to the end, whichever step that turns out to be: the button says `Next` until the last
        // one and `Done` on it, so tapping while it says `Next` is the walk that does not care how
        // many steps the screen had room for.
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

        // Skipped rather than finished, which is the exit that has to write the flag just as
        // firmly: it is the one somebody in the middle of something uses.
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

        resetTips(in: app)

        // MARK: A server, by hand

        tab("Servers", in: app).tap()

        // The Servers tab owes its own tips now that the row above has been pressed, and a tip is
        // a dimmed screen with one control lit: "Add a server" is behind it and the tap would land
        // on the dim. Answered here, which is also the only way to reach the button underneath.
        XCTAssertTrue(tip(serversFirstStep, in: app).waitForExistence(timeout: 10),
                      "the Servers screen's tips never appeared")
        app.buttons["Skip"].tap()
        XCTAssertTrue(
            tip(serversFirstStep, in: app).waitForNonExistence(timeout: 4),
            "Skip did nothing"
        )

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
