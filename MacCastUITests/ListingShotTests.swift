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
            "-Peering.seedAgentHistory", "1", "-Peering.showAllAgents", "1", "-Peering.seedAgentChat", "1", "-Peering.resumeWhenReachable", "0", "-Peering.lastHostID", "", "-Peering.lastHostName", "",
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
        if !row.waitForExistence(timeout: 8) { capture(app, "08-fail") }
        XCTAssertTrue(row.exists, "no demo window row")
        row.tap(); sleep(12)

        press(app, L["Shortcuts"]!); sleep(2)
        capture(app, "04-shortcuts")
        press(app, L["Shortcuts"]!); sleep(1)

        press(app, L["Keyboard"]!); sleep(2)
        capture(app, "03-keyboard")
        press(app, L["Hide keyboard"]!); sleep(6)
        capture(app, "02-session")

        press(app, L["Open Mac terminals"]!); sleep(3)
        let agents = app.buttons[L["Agents"]!].firstMatch
        if agents.waitForExistence(timeout: 4) { agents.tap(); sleep(2) }
        capture(app, "06-agents")

        let chat = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'orders-service'")).firstMatch
        if chat.waitForExistence(timeout: 6) { chat.tap(); sleep(3) }
        capture(app, "09-chat")
    }

    @MainActor
    func testChatScene() throws {
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
            "-Peering.seedAgentHistory", "1", "-Peering.showAllAgents", "1", "-Peering.seedAgentChat", "1",
            "-Peering.resumeWhenReachable", "0", "-Peering.lastHostID", "", "-Peering.lastHostName", "",
        ]
        app.launchEnvironment["PEERING_SEED_AGENT_CHAT"] = "1"
        app.launch()
        let more = app.buttons[L["More connection options"]!].firstMatch
        if more.waitForExistence(timeout: 20) {
            more.tap(); sleep(1)
            app.buttons[L["Connect via Relay"]!].firstMatch.tap()
        }
        XCTAssertTrue(app.buttons[L["Apps"]!].firstMatch.waitForExistence(timeout: 40), "not connected")
        sleep(4)
        press(app, L["Open Mac terminals"]!); sleep(3)
        let agents = app.buttons[L["Agents"]!].firstMatch
        if agents.waitForExistence(timeout: 4) { agents.tap(); sleep(2) }
        let chat = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'orders-service'")).firstMatch
        _ = chat.waitForExistence(timeout: 20)
        capture(app, "08-fail")
        XCTAssertTrue(chat.exists, "no seeded chat card")
        chat.tap(); sleep(3)
        capture(app, "09-chat")
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
