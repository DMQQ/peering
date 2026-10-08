import AppKit
import CoreGraphics
import Foundation
import RemoteCore
import ScreenCaptureKit
import os

extension ScreenCaptureSourceResolver {
    func bringOnScreen(_ source: CaptureSource) async {
        let windowID: CGWindowID
        switch source {
        case .window:
            // Streamed from wherever it is; the Mac goes there on the first touch. See ``OffDesktopInputGate``.
            return
        case .application(let pid):
            // An application's filter is built from its on-screen windows, and the snapshot's answer is from whichever desktop was showing when it was taken.
            guard !Self.hasOnScreenWindow(processID: pid),
                  let content = lock.withLock({ snapshot })
            else { markStale(); return }
            let owned = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
            let ownedIDs = owned.map(\.windowID)
            let elsewhere = await MainActor.run { windowsOrderedInOnSpaces(ownedIDs) }
            guard let first = ownedIDs.first(where: elsewhere.contains) else {
                markStale()
                return
            }
            windowID = first
        default:
            return
        }
        guard await MainActor.run(body: { switchToSpace(holding: windowID) }) else {
            markStale()
            return
        }
        try? await Task.sleep(for: Self.spaceSwitchSettle)
        markStale()
    }

    func makeFilter(for source: CaptureSource) throws -> CaptureFilterPlan {
        guard let content = lock.withLock({ isStale ? nil : snapshot }) else {
            throw CaptureError.catalogUnavailable
        }

        switch source {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureError.sourceUnavailable("That display is no longer attached.")
            }
            // Excluding rather than including: the empty exclusion list captures the whole display with desktop and menu bar.
            return CaptureFilterPlan(
                filter: SCContentFilter(display: display, excludingWindows: []),
                sourceRect: nil
            )

        case .application(let pid):
            guard let application = content.applications.first(where: { $0.processID == pid }) else {
                throw CaptureError.sourceUnavailable("That application is no longer running.")
            }
            let owned = content.windows.filter {
                $0.owningApplication?.processID == pid && Self.isUserFacingWindow($0)
            }
            guard !owned.isEmpty else {
                throw CaptureError.sourceUnavailable("That application has no windows on any display.")
            }

            // A single window is captured independently of its display, giving exactly the window size. With several, a display filter is the only option and `sourceRect` crops to their bounding box; otherwise the iPhone gets a large black canvas.
            if owned.count == 1 {
                return CaptureFilterPlan(
                    filter: SCContentFilter(desktopIndependentWindow: owned[0]),
                    sourceRect: nil
                )
            }

            guard let union = Self.unionFrame(of: owned),
                  let display = Self.hostingDisplay(for: union, in: content)
            else {
                throw CaptureError.sourceUnavailable("That application has no windows on any display.")
            }
            return CaptureFilterPlan(
                filter: SCContentFilter(
                    display: display,
                    including: [application],
                    exceptingWindows: []
                ),
                sourceRect: Self.sourceRect(for: union, on: display)
            )

        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureError.sourceUnavailable("That window has been closed.")
            }
            // Desktop-independent so it keeps capturing when covered or dragged to another display; a display filter would capture whatever is drawn on top.
            return CaptureFilterPlan(
                filter: SCContentFilter(desktopIndependentWindow: window),
                sourceRect: nil
            )

        case .mosaic:
            // Reachable only by mistake: a mosaic is captured as one filter per tile, and nothing on the Mac shows the canvas.
            throw CaptureError.sourceUnavailable(
                "A mosaic is composited from its tiles rather than captured in one piece."
            )
        }
    }

    /// `SCWindow.frame` is in global points (negative origin left of the primary) while `sourceRect` is in the display's own space; passing one for the other crops the wrong part.
    /// Clamped to the display: a crop partly outside it fails rather than being trimmed.
    private static func sourceRect(for union: CGRect, on display: SCDisplay) -> CGRect? {
        // Both sides are points (`display.frame`), or a Retina display halves the crop.
        let local = union.offsetBy(
            dx: -display.frame.origin.x,
            dy: -display.frame.origin.y
        )
        let within = local.intersection(CGRect(origin: .zero, size: display.frame.size))
        return within.isNull || within.isEmpty ? nil : within
    }

    private static func hostingDisplay(for rect: CGRect?, in content: SCShareableContent) -> SCDisplay? {
        guard let rect else { return content.displays.first }

        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetDisplaysWithRect(rect, 16, &ids, &count) == .success, count > 0,
           let match = content.displays.first(where: { $0.displayID == ids[0] }) {
            return match
        }
        return content.displays.first
    }
}
