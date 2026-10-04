import XCTest

final class LockShotTests: XCTestCase {
    @MainActor
    func testLockScreen() throws {
        let L = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "/Users/Shared/peering-labels.json")))) as? [String: String] ?? [:]
        let app = XCUIApplication()
        app.launchArguments = ["-Peering.hasSeenWelcome", "1", "-AppleLanguages", "(\(L["lang"] ?? "en"))", "-AppleLocale", L["locale"] ?? "en_US", "-Peering.clearDelivered", "1", "-Peering.resumeWhenReachable", "0", "-Peering.lastHostID", "", "-Peering.lastHostName", ""]
        addUIInterruptionMonitor(withDescription: "alerts") { alert in
            let n = alert.buttons.count
            if n > 0 { alert.buttons.element(boundBy: n - 1).tap(); return true }
            return false
        }
        app.launch()
        sleep(4)
        app.tap()
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(2)
        try? "home".write(toFile: "/Users/Shared/peering-home", atomically: true, encoding: .utf8)
        for _ in 0..<120 where !FileManager.default.fileExists(atPath: "/Users/Shared/peering-go") { sleep(1) }
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(10)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "10-lock"; shot.lifetime = .keepAlways; add(shot)
    }
}
