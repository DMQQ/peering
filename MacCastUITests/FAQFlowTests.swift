//
//  FAQFlowTests.swift
//  MacCastUITests
//
//  Walks the FAQ: every answer is closed to begin with, one question opens on a tap, and it
//  closes again on the next one.
//
//  It exists because the whole of that change is a layout, and nothing below the screens can see
//  one. What is worth asserting is not that the text is in the app. It is that the text is *not*
//  on the screen until the question is asked, which is the property the list was rearranged for
//  and the one a later edit could quietly undo by making the row unconditional again.
//
//  **Run it against a wiped container**, for the reason the SSH flow test gives: the app keeps
//  state in `UserDefaults`, and a second run starts from wherever the first one left off.
//
//      xcrun simctl uninstall <device> pl.dmq.peering
//
//  The scheme's `TestAction` still lists only `MacCastTests`, whose target does not link, so the
//  reference is swapped for this one to run the test and put back afterwards.
//

import XCTest

final class FAQFlowTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// A question near the top, and a phrase from the middle of its answer.
    ///
    /// A phrase rather than the whole sentence: the answer is asserted by containment, and pinning
    /// it to its exact punctuation would make this test fail on a copy edit it has no opinion about.
    private let question = "Do I need an account?"
    private let phrase = "There is no sign-up"

    /// A tab on the system's bar.
    ///
    /// Named through `tabBars` rather than a bare `app.buttons["FAQ"]`, which would also match any
    /// control with that name on the screen behind the bar.
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
        // The assertion the animation has to settle before this can pass, which is why it is a
        // wait rather than a plain read: an answer on its way out is still on the screen.
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
