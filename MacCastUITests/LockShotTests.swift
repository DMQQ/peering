import XCTest

final class LockShotTests: XCTestCase {
    @MainActor
    func testLockScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-Peering.hasSeenWelcome", "1", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-Peering.resumeWhenReachable", "0", "-Peering.lastHostID", "", "-Peering.lastHostName", ""]
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
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(3)
        try? "locked".write(toFile: "/Users/Shared/peering-locked", atomically: true, encoding: .utf8)
        sleep(28)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "10-lock"; shot.lifetime = .keepAlways; add(shot)
    }
}
