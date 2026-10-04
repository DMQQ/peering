import XCTest

/// Drives one language through the screens an App Store listing shows, against a real Mac host.
/// Reads its labels from /Users/Shared/peering-labels.json so one test serves every language.
final class ListingShotTests: XCTestCase {
    private var skipLabel = "Skip"

    @MainActor
    func testScenes() throws {
        continueAfterFailure = false
        let raw = try Data(contentsOf: URL(fileURLWithPath: "/Users/Shared/peering-labels.json"))
        let L = try JSONSerialization.jsonObject(with: raw) as! [String: String]
        skipLabel = L["Skip"]!
        let app = XCUIApplication()
        app.launchArguments = [
            "-Peering.hasSeenWelcome", "1", "-Peering.hasSeenTourConnect", "1",
            "-Peering.hasSeenTourServers", "1", "-Peering.hasSeenTourShell", "1",
            "-Peering.hasSeenTourTerminal", "1", "-Peering.hasSeenTourScreen", "1",
            "-AppleLanguages", "(\(L["lang"]!))", "-AppleLocale", L["locale"]!,
            "-Peering.seedAgentHistory", "1", "-Peering.resumeWhenReachable", "0", "-Peering.lastHostID", "", "-Peering.lastHostName", "",
        ]
        addUIInterruptionMonitor(withDescription: "alerts") { alert in
            let n = alert.buttons.count
            if n > 0 { alert.buttons.element(boundBy: n - 1).tap(); return true }
            return false
        }
        app.launch()
        sleep(4)
        let leftover = app.buttons[L["Apps"]!].firstMatch
        if leftover.exists {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'MacBook'")).firstMatch.tap(); sleep(1)
            press(app, L["Quit"]!); sleep(4)
        }
        capture(app, "01-connect")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.845, dy: 0.947)).tap(); sleep(2)
        capture(app, "05-settings")
        app.terminate(); app.launch(); sleep(5)

        var inSession = false
        for attempt in 0..<3 where !inSession {
            let more = app.buttons[L["More connection options"]!].firstMatch
            if more.waitForExistence(timeout: 20) {
                more.tap(); sleep(1)
                app.buttons[L["Connect via Relay"]!].firstMatch.tap()
            }
            inSession = app.buttons[L["Apps"]!].firstMatch.waitForExistence(timeout: 40)
            if !inSession && attempt < 2 { app.terminate(); app.launch(); sleep(5) }
        }
        sleep(4)

        press(app, L["Apps"]!); sleep(3)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'orders-service'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "no demo window row")
        row.tap(); sleep(12)

        press(app, L["Shortcuts"]!); sleep(2)
        capture(app, "04-shortcuts")
        press(app, L["Shortcuts"]!); sleep(1)

        press(app, L["Keyboard"]!); sleep(2)
        capture(app, "03-keyboard")
        press(app, L["Hide keyboard"]!); sleep(6)
        capture(app, "02-session")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        let agents = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", L["Agents"]!)).firstMatch
        if !agents.waitForExistence(timeout: 4) { capture(app, "08-fail"); XCTFail("missing Agents: \(app.buttons.allElementsBoundByIndex.map { $0.label })") }
        agents.tap(); sleep(3)
        capture(app, "06-agents")
    }

    @MainActor
    private func press(_ app: XCUIApplication, _ label: String) {
        let skip = app.buttons[skipLabel].firstMatch
        if skip.exists { skip.tap(); sleep(1) }
        let b = app.buttons[label].firstMatch
        if !b.waitForExistence(timeout: 12) {
            capture(app, "08-fail")
            XCTFail("missing \(label)")
            return
        }
        b.tap()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
