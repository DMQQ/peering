//
//  SSHLockFlowTests.swift
//  PeeringUITests
//
// Walks the Servers-tab work end to end: save a server with a passcode lock, try a wrong then the right passcode, sign in, and find the refused shell in the connection log.
// **Run it against a wiped container.** Servers persist in `UserDefaults`, so a second run matches two rows:
//
//      xcrun simctl uninstall 825ECC2B-F0D1-439A-9F1B-AD942DFE178F pl.dmq.peering
//
// The scheme has no `<Testables>`, so `xcodebuild test` refuses until a `TestableReference` for `PeeringUITests` is added to `Peering.xcscheme` (temporary edit).
//
// Nothing listens on the simulator's loopback at port 22, so the shell is refused within a second, which produces the log entry. With Remote Login on, the app would wait for a password.
//
// Do not add a launch argument that grants a plan: `StoreManager.activeTier` is also claimed to the relay, which believes claims without a receipt.

import XCTest

final class SSHLockFlowTests: XCTestCase {

    private let passcode = "481620"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Via `tabBars`: a bare `app.buttons["Servers"]` also matches the back button.
    private func tab(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons[name]
    }

    @MainActor
    func testLockingAServerWithAPasscode() throws {
        let app = XCUIApplication()
        // Argument domain: seeding the container plist does not outrank the app's own defaults.
        app.launchArguments = [
            "-Peering.hasSeenWelcome", "1", "-Peering.hasSeenTourConnect", "1", "-Peering.hasSeenTourServers", "1",
            "-Peering.hasSeenTourShell", "1", "-Peering.hasSeenTourTerminal", "1", "-Peering.hasSeenTourScreen", "1",
        ]
        app.launch()

        tab("Servers", in: app).tap()
        capture(app, "1-servers-tab")

        app.buttons["Add a server"].tap()

        // Nothing listens on loopback, so the shell is refused and the failure is still logged.
        let host = app.textFields["box.example.com"]
        XCTAssertTrue(host.waitForExistence(timeout: 5), "the Host field never appeared")
        host.tap()
        host.typeText("127.0.0.1")

        let user = app.textFields["root"]
        user.tap()
        user.typeText("deploy")
        capture(app, "2-editor-filled")

        picker(named: "Ask for", in: app).tap()
        app.buttons["Passcode"].tap()
        capture(app, "3-lock-chosen")

        app.buttons["Set"].tap()
        XCTAssertTrue(app.staticTexts["Choose a passcode"].waitForExistence(timeout: 5),
                      "the passcode pad never appeared")
        tapDigits(passcode, in: app)
        XCTAssertTrue(app.staticTexts["Type it again"].waitForExistence(timeout: 5),
                      "the pad did not ask for the passcode a second time")
        tapDigits(passcode, in: app)
        capture(app, "4-passcode-set")

        app.buttons["Add server"].tap()

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "127.0.0.1")).firstMatch.waitForExistence(timeout: 5),
                      "the server was not saved")
        capture(app, "5-server-listed")

        app.staticTexts.matching(NSPredicate(format: "label == %@", "127.0.0.1")).allElementsBoundByIndex.last?.tap()

        XCTAssertTrue(app.staticTexts["Locked"].waitForExistence(timeout: 5),
                      "tapping a locked server did not raise the lock")
        capture(app, "6-lock-sheet")

        // Wrong passcode first, to prove the refusal comes from the server's passcode.
        tapDigits("999999", in: app)
        XCTAssertTrue(app.staticTexts["That passcode is not right for this server."].waitForExistence(timeout: 5),
                      "a wrong passcode was not refused")
        capture(app, "7-wrong-passcode")

        tapDigits(passcode, in: app)

        // The pad should be gone; the connection failing is not what is asserted.
        XCTAssertTrue(app.staticTexts["Locked"].waitForNonExistence(timeout: 5),
                      "the right passcode did not open the server")
        capture(app, "8-through-the-gate")

        // No stored password, so the sign-in sheet comes up; any password will do since the shell is refused.
        let passwordField = app.textFields["Password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 8), "the sign-in sheet never appeared")
        passwordField.tap()
        passwordField.typeText("hunter2")

        // Scoped to the sheet: `buttons["Connect"]` is also the first tab's name.
        let inSheet = app.sheets.buttons["Connect"].firstMatch
        let connect = inSheet.exists ? inSheet : app.navigationBars.buttons["Connect"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "the sign-in sheet had nothing to tap")
        connect.tap()

        // `New shell` is the toolbar item only the shell screen has.
        XCTAssertTrue(app.buttons["New shell"].waitForExistence(timeout: 15),
                      "the shell screen never came up after signing in")

        // The tab bar is hidden while a shell is up, so use the leading item, not `buttons["Servers"]`.
        leaveShellScreen(in: app)

        // The failed connection is logged in the Sessions tab like any other.
        tab("Sessions", in: app).tap()

        let failure = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Failed ·"))
            .firstMatch

        if !failure.waitForExistence(timeout: 10) {
            // The card sits below the fold on this screen.
            app.swipeUp()
        }

        XCTAssertTrue(failure.waitForExistence(timeout: 30),
                      "the failed shell was never written to the connection log")
        capture(app, "9-log-in-sessions")
    }

    // MARK: - Helpers

    /// By position: the item is named "Servers", like the tab bar button, and a query matching both fails.
    @MainActor
    private func leaveShellScreen(in app: XCUIApplication) {
        let bar = app.navigationBars.firstMatch
        guard bar.waitForExistence(timeout: 5), bar.buttons.count > 0 else {
            XCTFail("no way off the shell screen:\n\(app.debugDescription)")
            return
        }
        bar.buttons.element(boundBy: 0).tap()
    }

    @MainActor
    private func tapDigits(_ digits: String, in app: XCUIApplication) {
        for character in digits {
            app.buttons[String(character)].tap()
        }
    }

    /// Found by the name the row gives it, since its visible title is hidden.
    @MainActor
    private func picker(named name: String, in app: XCUIApplication) -> XCUIElement {
        let byLabel = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        if byLabel.waitForExistence(timeout: 3) { return byLabel }
        // Fall back to the value it is showing, which for an untouched lock is "Nothing".
        return app.buttons["Nothing"].firstMatch
    }

    /// The exported files are UUIDs, so the name goes in the manifest.
    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
