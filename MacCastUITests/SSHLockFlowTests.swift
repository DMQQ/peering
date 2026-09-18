//
//  SSHLockFlowTests.swift
//  MacCastUITests
//
//  Walks the Servers-tab work end to end: save a server with a passcode lock, see it listed with
//  the lock on it, tap it and get the pad, be refused a wrong passcode, be let through by the right
//  one, sign in, and find the failed shell written to the connection log in the Sessions tab.
//
//  It exists because the lock is the one part of that feature no unit test can reach — what is
//  behind the gate is asserted in `SSHCoreTests` and what is in front of it is screens — and
//  because a simulator is the only place the two tabs can be seen together at all.
//
//  **Run it against a wiped container.** The app keeps its servers in `UserDefaults`, so a second
//  run finds the first run's server still in the list and every `staticTexts["127.0.0.1"]` matches
//  two rows:
//
//      xcrun simctl uninstall 825ECC2B-F0D1-439A-9F1B-AD942DFE178F pl.dmq.peering
//
//  The scheme's `TestAction` also has no `<Testables>`, so `xcodebuild test` refuses with "Scheme
//  MacCast is not currently configured for the test action" until a `TestableReference` for
//  `MacCastUITests` is added to `MacCast.xcscheme` — a temporary edit, because the scheme is
//  already dirty in the worktree.
//
//  Nothing listens on the simulator's loopback at port 22, so the shell is refused within a second
//  — which is what produces the log entry. If macOS Remote Login is ever turned on, the app will
//  instead sit waiting for a password that this test never gives it.
//

import XCTest

final class SSHLockFlowTests: XCTestCase {

    /// The passcode the test sets and then types back.
    private let passcode = "481620"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLockingAServerWithAPasscode() throws {
        let app = XCUIApplication()
        // The argument domain, because seeding the container plist does not outrank the app's own
        // defaults — see the note in the project's agent notes.
        app.launchArguments = ["-Peering.hasSeenWelcome", "1"]
        app.launch()

        app.tabBars.buttons["Servers"].tap()
        capture(app, "1-servers-tab")

        app.buttons["Add a server"].tap()

        // The simulator's own loopback, where nothing is listening: the shell is refused within a
        // second or so, which is a *record* — a failed connection is as much a line in the log as a
        // successful one, and it is the only way to reach that row from a simulator with no server
        // to dial.
        let host = app.textFields["box.example.com"]
        XCTAssertTrue(host.waitForExistence(timeout: 5), "the Host field never appeared")
        host.tap()
        host.typeText("127.0.0.1")

        let user = app.textFields["root"]
        user.tap()
        user.typeText("deploy")
        capture(app, "2-editor-filled")

        // The lock picker, which is a menu wearing a row's label.
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

        // The badge is the whole of what tells a user this server is going to ask for something.
        XCTAssertTrue(app.staticTexts["127.0.0.1"].waitForExistence(timeout: 5),
                      "the server was not saved")
        capture(app, "5-server-listed")

        app.staticTexts["127.0.0.1"].tap()

        XCTAssertTrue(app.staticTexts["Locked"].waitForExistence(timeout: 5),
                      "tapping a locked server did not raise the lock")
        capture(app, "6-lock-sheet")

        // The wrong one first, so the refusal is proved to come from the server's passcode rather
        // than from the sheet simply opening on anything.
        tapDigits("999999", in: app)
        XCTAssertTrue(app.staticTexts["That passcode is not right for this server."].waitForExistence(timeout: 5),
                      "a wrong passcode was not refused")
        capture(app, "7-wrong-passcode")

        tapDigits(passcode, in: app)

        // Through the gate: the sheet goes and the shell screen takes its place. It is about to
        // fail to connect, which is not what is being asserted — the assertion is that the pad is
        // gone and something on the other side of it is not.
        XCTAssertTrue(app.staticTexts["Locked"].waitForNonExistence(timeout: 5),
                      "the right passcode did not open the server")
        capture(app, "8-through-the-gate")

        // The gate is open and there is no stored password for this server, so the sign-in sheet is
        // what comes up next — the same sheet an unlocked row raises, which is itself worth seeing.
        // Anything will do for the password: nothing is listening at the other end, so the shell is
        // refused whichever one it was given, and a refusal is what this test is trying to produce.
        let passwordField = app.textFields["Password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 8), "the sign-in sheet never appeared")
        passwordField.tap()
        passwordField.typeText("hunter2")

        // Not `app.buttons["Connect"]`, which is also the name of the tab bar's first tab. Scoped
        // to the sheet, and falling back to the navigation bar it is presented in.
        let inSheet = app.sheets.buttons["Connect"].firstMatch
        let connect = inSheet.exists ? inSheet : app.navigationBars.buttons["Connect"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "the sign-in sheet had nothing to tap")
        connect.tap()

        // The shell screen, and then the refusal. `New shell` is the toolbar item only that screen
        // has, so waiting on it is waiting for the sign-in sheet to have gone somewhere real.
        XCTAssertTrue(app.buttons["New shell"].waitForExistence(timeout: 15),
                      "the shell screen never came up after signing in")

        // Back out of the terminal before going anywhere else, because the tab bar is hidden while
        // a shell is up — deliberately, it is a full-screen terminal — so there is no tab to tap
        // until this screen has been left. The leading item, not `buttons["Servers"]`, which is
        // also the name of the tab bar's own button on the screen this is trying to get back to.
        leaveShellScreen(in: app)

        // The log lives in the Sessions tab, beside the Mac sessions — one list of everything this
        // phone has connected to. The shell cannot reach anything, and a connection that failed is
        // written to that list like any other. That row is the half of this feature a simulator has
        // no other way to see, because seeing it with a *successful* connection needs a server.
        app.tabBars.buttons["Sessions"].tap()

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

    /// Leaves the shell screen for the list, by the leading item in its navigation bar.
    ///
    /// By position rather than by name, because the name it carries is "Servers" — the same word as
    /// the tab bar button this screen is trying to bring back, and a query that matches both is a
    /// query that fails on a screen where only one of them exists.
    @MainActor
    private func leaveShellScreen(in app: XCUIApplication) {
        let bar = app.navigationBars.firstMatch
        guard bar.waitForExistence(timeout: 5), bar.buttons.count > 0 else {
            XCTFail("no way off the shell screen:\n\(app.debugDescription)")
            return
        }
        bar.buttons.element(boundBy: 0).tap()
    }

    /// The pad, key by key. `PasscodePad` gives every digit key its digit as its label.
    @MainActor
    private func tapDigits(_ digits: String, in app: XCUIApplication) {
        for character in digits {
            app.buttons[String(character)].tap()
        }
    }

    /// A `Controls.picker` row: a menu whose visible title is hidden, so it is found by the name
    /// the row gives it rather than by the value it is showing.
    @MainActor
    private func picker(named name: String, in app: XCUIApplication) -> XCUIElement {
        let byLabel = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        if byLabel.waitForExistence(timeout: 3) { return byLabel }
        // Fall back to the value it is showing, which for an untouched lock is "Nothing".
        return app.buttons["Nothing"].firstMatch
    }

    /// Keeps a screenshot under a name that means something once it is exported, because the
    /// exported files are UUIDs and the manifest is the only thing that maps them back.
    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
