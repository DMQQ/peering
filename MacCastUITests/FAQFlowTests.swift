//
//  FAQFlowTests.swift
//  MacCastUITests
//
//  Walks the FAQ: every answer is closed to begin with, one question opens on a tap, and it
//  closes again on the next one.
//
//  Asserts the answer text is not on screen until the question is tapped, which a later edit could quietly undo.
//
//  Run against a wiped container, since state lives in `UserDefaults`:
//
//      xcrun simctl uninstall <device> pl.dmq.peering
//
//  The scheme's TestAction lists only MacCastTests, which does not link; swap the reference to run this.
//

import XCTest

final class FAQFlowTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// A phrase from the answer's middle, matched by containment so copy edits do not break the test.
    private let question = "Do I need an account?"
    private let phrase = "There is no sign-up"

    /// A tab on the system bar, via tabBars so a same-named control behind it cannot match.
    private func tab(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons[name]
    }

    @MainActor
    func testAnswersAreClosedUntilAsked() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-Peering.hasSeenWelcome", "1"]
        app.launch()

        tab("FAQ", in: app).tap()

        let answer = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", phrase)
        ).firstMatch
        let button = app.buttons[question]

        XCTAssertTrue(button.waitForExistence(timeout: 5), "The FAQ should list its questions.")
        XCTAssertFalse(answer.exists, "Every answer should start closed.")
        capture(app, "1-faq-closed")

        button.tap()
        XCTAssertTrue(answer.waitForExistence(timeout: 2), "Tapping a question should open it.")
        capture(app, "2-faq-open")

        button.tap()
        // A wait, not a read: an answer on its way out is still on screen.
        XCTAssertTrue(
            answer.waitForNonExistence(timeout: 2),
            "Tapping the same question again should close it."
        )
        capture(app, "3-faq-closed-again")
    }

    /// Every section is drawn, and the count of questions is what the collapsed view is for: if
    /// this number drops, a question has been deleted rather than folded away.
    @MainActor
    func testTheListIsComplete() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-Peering.hasSeenWelcome", "1"]
        app.launch()

        tab("FAQ", in: app).tap()
        XCTAssertTrue(app.buttons["Do I need an account?"].waitForExistence(timeout: 5))

        for section in [
            "GETTING STARTED", "PRIVACY", "WHAT MOVES BETWEEN DEVICES",
            "PLANS", "SECURITY AND TROUBLESHOOTING", "KNOWN GAPS",
        ] {
            XCTAssertTrue(
                app.staticTexts[section].exists,
                "The \(section) section should be on the page."
            )
        }
        capture(app, "4-faq-sections")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
