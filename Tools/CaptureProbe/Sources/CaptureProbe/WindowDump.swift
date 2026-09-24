import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Every window the enumeration offers, with everything both APIs say about each one.
///
/// **Written to answer one question: what *is* a window with no name.** A window titled "Window"
/// turned up in the picker, photographed as a black rectangle and unpressable, and nothing the
/// catalogue carries told it apart from a real window — so the two APIs are dumped side by side,
/// for the same window numbers, including the fields the catalogue never reads: the alpha, the
/// store type, the memory the window server has behind it, and whether CoreGraphics agrees with
/// ScreenCaptureKit about it being on screen.
///
/// Run it with `Tools/CaptureProbe/run-capture-probe.sh --windows`.
extension CaptureProbe {
    static func dumpWindows() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            )
        } catch {
            throw ProbeError(message: """
                the enumeration failed: \(error.localizedDescription). Screen Recording is \
                \(CGPreflightScreenCaptureAccess() ? "granted" : "NOT granted").
                """)
        }

        // Everything the window server knows, by window number, so the two answers can be read
        // against each other rather than one at a time.
        let info = (CGWindowListCopyWindowInfo(
            [.optionAll],
            kCGNullWindowID
        ) as? [[String: Any]]) ?? []
        var byID: [CGWindowID: [String: Any]] = [:]
        for entry in info {
            if let id = entry[kCGWindowNumber as String] as? CGWindowID {
                byID[id] = entry
            }
        }

        log("\(content.windows.count) window(s) from ScreenCaptureKit, \(info.count) from CoreGraphics")

        let named = content.windows.filter { window in
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.lowercased() == "window"
        }
        log("\(named.count) of them titled exactly \"Window\"")

        for window in content.windows.sorted(by: { $0.windowID < $1.windowID }) {
            let entry = byID[window.windowID]
            let owner = window.owningApplication?.applicationName ?? "?"
            let pid = window.owningApplication?.processID ?? 0
            let frame = window.frame
            let frameText = "\(Int(frame.origin.x)),\(Int(frame.origin.y)) "
                + "\(Int(frame.width))×\(Int(frame.height))"
            let cgOnScreen = describe(entry?[kCGWindowIsOnscreen as String])

            log("")
            log("window \(window.windowID) · \(owner) (pid \(pid))")
            log("  title        \((window.title ?? "<none>").debugDescription)")
            log("  layer        \(window.windowLayer)   on screen \(window.isOnScreen) (CoreGraphics \(cgOnScreen))")
            log("  frame        \(frameText)")
            log("  alpha        \(describe(entry?[kCGWindowAlpha as String]))")
            log("  store type   \(describe(entry?[kCGWindowStoreType as String]))")
            log("  sharing      \(describe(entry?[kCGWindowSharingState as String]))")
            log("  memory       \(describe(entry?[kCGWindowMemoryUsage as String]))")
            log("  coregraphics \(describe(entry?[kCGWindowBounds as String]))")
        }
    }

    /// The value of one CoreGraphics key, whatever type it turns out to be.
    private static func describe(_ value: Any?) -> String {
        guard let value else { return "-" }
        return "\(value)"
    }
}
