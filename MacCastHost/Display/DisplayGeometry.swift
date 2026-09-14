import CoreGraphics
import Foundation
import RemoteCore

/// Builds the normalized→global mapping for a physical display.
///
/// This deliberately avoids ScreenCaptureKit. `CGDisplayBounds` and `CGDisplayPixelsWide`
/// answer the two questions a coordinate mapping needs — where the display is in the global
/// space, and how many pixels it actually has — without a capture stream, which means input
/// injection can be built and verified before any of the capture pipeline exists.
enum DisplayGeometry {
    /// The transform for a display, or `nil` if it is not a display the system knows about.
    ///
    /// `CGDisplayBounds` is in **points**, while `CGDisplayPixelsWide` is in **pixels**.
    /// The ratio between them is the backing scale, and it is not always 2: an external
    /// 4K display at a scaled resolution reports a great many pixels over comparatively
    /// few points. Computing it rather than assuming 2.0 is what keeps the remote cursor
    /// from drifting on anything but a built-in Retina panel.
    static func transform(for displayID: CGDirectDisplayID) -> InputTransform? {
        let bounds = CGDisplayBounds(displayID)
        let width = CGDisplayPixelsWide(displayID)
        let height = CGDisplayPixelsHigh(displayID)

        guard bounds.width > 0, bounds.height > 0, width > 0, height > 0 else { return nil }

        return InputTransform(
            origin: bounds.origin,
            pixelSize: CGSize(width: width, height: height),
            pointPixelScale: CGFloat(width) / bounds.width
        )
    }

    /// Every display under the pointer, in the order the window server reports them.
    ///
    /// The main display comes back rather than an empty list when the query fails, so no caller
    /// has to handle "no display at all" — on a machine with a screen there is always one.
    static func pointerDisplayIDs() -> [CGDirectDisplayID] {
        let point = CGEvent(source: nil)?.location ?? .zero
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)

        guard CGGetDisplaysWithPoint(point, 16, &displays, &count) == .success, count > 0 else {
            return [CGMainDisplayID()]
        }
        return Array(displays.prefix(Int(count)))
    }

    /// The display the pointer is on, falling back to the main display.
    ///
    /// "Main" is not "the active one": on a multi-display Mac a user can be looking at a
    /// secondary screen, and anything that acts on "the display the user means" — mapping input,
    /// switching a Space — has to ask where the pointer is rather than assume.
    static func pointerDisplayID() -> CGDirectDisplayID {
        pointerDisplayIDs().first ?? CGMainDisplayID()
    }

    /// The transform for the display the pointer is on, falling back to the main display.
    static func activeTransform() -> InputTransform? {
        for display in pointerDisplayIDs() {
            if let transform = transform(for: display) { return transform }
        }
        return transform(for: CGMainDisplayID())
    }
}
