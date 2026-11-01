import AppKit
import CoreGraphics

/// Accessibility queries that land on one of this app's own windows are served in-process on the calling thread, so
/// off the main thread they run SwiftUI's accessibility against its view-graph lock. With the main thread inside a
/// layout that deadlocks the host for good (the picture stops and the window freezes), so callers check here first.
enum OwnWindows {
    /// Read from the window server, not AppKit: NSWindow is main-thread state. The list is front to back, so the
    /// frontmost window under the point decides. The server does not report `ignoresMouseEvents`, so windows a hit
    /// test passes through are told apart by alpha 0 or a screen-saver layer (the privacy curtain sits there).
    static func contains(_ point: CGPoint) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let me = getpid()
        for window in windows where takesHits(window) {
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.contains(point)
            else { continue }
            return (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == me
        }
        return false
    }

    private static let overlayLayer = Int(CGWindowLevelForKey(.screenSaverWindow))

    private static func takesHits(_ window: [String: Any]) -> Bool {
        let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        return alpha > 0 && layer < overlayLayer
    }

    /// True while this app is the active one, when a system-wide focus query would be answered by its own windows.
    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
    }
}
