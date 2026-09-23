import CoreGraphics
import Foundation
import RemoteCore

/// Builds the normalized→global mapping for a physical display.
///
/// Uses `CGDisplayBounds` and `CGDisplayPixelsWide` rather than ScreenCaptureKit, so the
/// mapping needs no capture stream.
enum DisplayGeometry {
/// The transform for a display, or `nil` if it is not a display the system knows about.
///
/// `CGDisplayBounds` is in points and `CGDisplayPixelsWide` in pixels. The ratio is the backing
/// scale and is not always 2, so it is computed rather than assumed.
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
/// The main display comes back rather than an empty list when the query fails, so no caller has
/// to handle "no display at all".
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
/// "Main" is not "the active one": on a multi-display Mac, anything acting on "the display the
/// user means" has to ask where the pointer is rather than assume.
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
