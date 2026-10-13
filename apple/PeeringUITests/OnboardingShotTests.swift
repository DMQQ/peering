//
//  OnboardingShotTests.swift
//  PeeringUITests
//
// Screenshots a page of the first-run tour to check its art resolves and fits the frame. Same job as `PaywallShotTests`.
//  Run it against the simulator whose screen you want the picture at, and export the attachment:
//
//      xcodebuild test -scheme Peering -destination 'id=<device-udid>' \
//        -only-testing:PeeringUITests/OnboardingShotTests -resultBundlePath /tmp/ui.xcresult
//      xcrun xcresulttool export attachments --path /tmp/ui.xcresult --output-path /tmp/shots
//
// The scheme's `TestAction` lists `PeeringTests`, which does not build, so `xcodebuild test` refuses until its `TestableReference` is dropped from `Peering.xcscheme` (put it back afterwards).

import XCTest

final class OnboardingShotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func settle(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    @MainActor
    private func photographPage(titled title: String, taps: Int) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-Peering.hasSeenWelcome", "0"]
        app.launch()

        // Hittable, not merely present: the button fades in after it enters the tree, and an early tap is dropped.
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
