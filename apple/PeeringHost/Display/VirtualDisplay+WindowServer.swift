import CoreGraphics
import Foundation

extension VirtualDisplay {
    // MARK: - The window server's view

/// CGGetActiveDisplayList, not NSScreen.screens: a virtual display may or may not be in AppKit's list.
    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        guard CGGetActiveDisplayList(32, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func waitForAppearance(of displayID: CGDirectDisplayID, timeout: TimeInterval = 3) -> Bool {
        wait(timeout: timeout) { activeDisplayIDs().contains(displayID) }
    }

    static func waitForDeparture(of displayID: CGDirectDisplayID, timeout: TimeInterval = 3) -> Bool {
        wait(timeout: timeout) { !activeDisplayIDs().contains(displayID) }
    }

/// On the main thread the run loop is turned, not slept: the window server waits for the main run loop to answer a display change, which a sleeping thread cannot do.
    static func wait(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            if Thread.isMainThread {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return condition()
    }

/// 460 ppi; only the descriptor's bookkeeping uses it.
    static func millimetres(for size: CGSize) -> CGSize {
        let millimetresPerPixel = 25.4 / 460
        return CGSize(width: size.width * millimetresPerPixel, height: size.height * millimetresPerPixel)
    }
}
