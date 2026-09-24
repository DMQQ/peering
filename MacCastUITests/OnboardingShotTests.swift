//
//  OnboardingShotTests.swift
//  MacCastUITests
//
//  Photographs a page of the first-run tour so the picture in its frame can be looked at. That is
//  the one thing about a page's art nothing below can check: an asset catalog entry that compiles
//  is not an asset catalog entry that resolves, and what the frame does with a capture whose
//  proportions are not the frame's own is a fact about a screen. Same job as `PaywallShotTests`.
//
//  Run it against the simulator whose screen you want the picture at, and export the attachment:
//
//      xcodebuild test -scheme MacCast -destination 'id=<device-udid>' \
//        -only-testing:MacCastUITests/OnboardingShotTests -resultBundlePath /tmp/ui.xcresult
//      xcrun xcresulttool export attachments --path /tmp/ui.xcresult --output-path /tmp/shots
//
//  As committed, the scheme's `TestAction` also lists `MacCastTests`, and that bundle does not
//  build under this Xcode (everything runnable lives in `MacCastKit`), so `xcodebuild test`
//  refuses until its `TestableReference` is dropped from `MacCast.xcscheme` and put back
//  afterwards. The same temporary edit the other tests in this target describe.
//
//  `taps` is the number of pages to turn from the first, and the title is asserted before the
//  screenshot: a picture of the wrong page is worse than no picture.
//

import XCTest

final class OnboardingShotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Waits for an element to be something a tap can land on, which is later than the frame it
    /// appears in the tree.
    @MainActor
    private func settle(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// Walks the welcome flow to a page of the tour, by the title that page carries, and keeps a
    /// screenshot of it.
    @MainActor
    private func photographPage(titled title: String, taps: Int) throws {
        let app = XCUIApplication()
        // The argument domain, so it lasts the launch and writes nothing down.
        app.launchArguments = ["-Peering.hasSeenWelcome", "0"]
        app.launch()

        // **Hittable, not merely present.** The landing's button fades in with its last claim, so
        // it is in the tree before it is on the screen, and a tap on the frames before it arrives
        // is a tap SwiftUI drops: the run sat on the landing for its whole fifteen-second wait
        // with the button drawn under the finger.
        let start = app.buttons["See how it works"]
        XCTAssertTrue(start.waitForExistence(timeout: 15), "the landing never arrived")
        XCTAssertTrue(settle(start), "the landing's button never became hittable")
        start.tap()

        let next = app.buttons["Next"]
        XCTAssertTrue(next.waitForExistence(timeout: 15), "the tour never arrived")
        XCTAssertTrue(settle(next), "the tour's button never became hittable")

        for _ in 0..<taps {
            next.tap()
            // The pages swap on a spring, and a tap during one is a tap the pager drops.
            Thread.sleep(forTimeInterval: 1.0)
        }

        XCTAssertTrue(
            app.staticTexts[title].waitForExistence(timeout: 5),
            "expected the page called \(title)"
        )

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "tour-\(title)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testMosaicPage() throws {
        try photographPage(titled: "See everything at once", taps: 5)
    }
}
