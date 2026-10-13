//
//  FilesTabTests.swift
//  PeeringUITests
//
//  The hub's Files tab on the pretend Mac: where it opens and what it lists.
//

import XCTest

final class FilesTabTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFilesTabNamesTheFolderItOpensIn() throws {
        let app = SeededAgentChat.launch(scenario: "empty")
        let terminals = app.buttons["Open Mac terminals"]
        XCTAssertTrue(terminals.waitForExistence(timeout: 15), "The pretend Mac never reached its session screen:\n\(app.debugDescription)")
        terminals.tap()

        let files = app.buttons["Files"]
        XCTAssertTrue(files.waitForExistence(timeout: 5), "The hub should offer Files:\n\(app.debugDescription)")
        files.tap()

        XCTAssertTrue(app.staticTexts["Documents"].waitForExistence(timeout: 5), "The home folder should be listed:\n\(app.debugDescription)")
        snap(app, "2-files-home")
        XCTAssertTrue(app.staticTexts["/Users/demo"].exists, "The bar should name the folder Files opened in:\n\(app.debugDescription)")
    }

    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

extension FilesTabTests {
    @MainActor
    func testLongLinesScrollSidewaysWhenWrappingIsOff() throws {
        let app = SeededAgentChat.launch(scenario: "empty")
        app.buttons["Open Mac terminals"].tap()
        app.buttons["Files"].tap()
        let notes = app.staticTexts["notes.txt"]
        XCTAssertTrue(notes.waitForExistence(timeout: 10), "The file should be listed:\n\(app.debugDescription)")
        notes.tap()

        let text = app.textViews.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5), "The preview should show the text:\n\(app.debugDescription)")
        snap(app, "3-preview-wrapped")

        let scroll = app.buttons["Scroll long lines"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 3), "The preview should offer to stop wrapping.")
        scroll.tap()
        snap(app, "4-preview-unwrapped")

        let before = text.screenshot().pngRepresentation
        text.swipeLeft()
        snap(app, "5-preview-scrolled-sideways")
        XCTAssertNotEqual(text.screenshot().pngRepresentation, before, "Swiping left should move the text sideways when lines are not wrapped.")
    }
}
