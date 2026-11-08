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
        SeededAgentChat.openHub(app)

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
        SeededAgentChat.openHub(app)
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

extension FilesTabTests {
    @MainActor
    func testOpeningAFolderListsItInPlaceAndOnlyAFilePushesAPage() throws {
        let app = SeededAgentChat.launch(scenario: "empty")
        SeededAgentChat.openHub(app)
        app.buttons["Files"].tap()

        let documents = app.staticTexts["Documents"]
        XCTAssertTrue(documents.waitForExistence(timeout: 10), "The home folder should be listed:\n\(app.debugDescription)")
        documents.tap()

        XCTAssertTrue(app.staticTexts["orders-service"].waitForExistence(timeout: 5), "The folder's own listing should replace the list:\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["/Users/demo/Documents"].exists, "The bar should name the folder it moved to:\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Files"].exists, "A folder opens in the hub's own tab: no page should have been pushed over it.")
        snap(app, "6-files-in-place")

        let up = app.staticTexts[".."]
        XCTAssertTrue(up.waitForExistence(timeout: 3), "A folder below home should offer a way up:\n\(app.debugDescription)")
        up.tap()
        XCTAssertTrue(app.staticTexts["Documents"].waitForExistence(timeout: 5), "Going up should list the home folder again:\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["/Users/demo"].exists, "The bar should name the folder it came back to.")

        documents.tap()
        let readme = app.staticTexts["README.md"]
        XCTAssertTrue(readme.waitForExistence(timeout: 5))
        readme.tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5), "A file should open its preview page:\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["Files"].exists && app.buttons["Files"].isHittable, "The preview is a page of its own over the hub.")
    }
}
