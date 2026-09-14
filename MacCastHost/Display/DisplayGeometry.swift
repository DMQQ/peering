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

    /// The transform for the display the pointer is on, falling back to the main display.
    ///
    /// "Main" is not "the active one": on a multi-display Mac a user can be looking at a
    /// secondary screen, and mapping input to the main display would drive the cursor
    /// somewhere they are not looking.
    static func activeTransform() -> InputTransform? {
        let point = CGEvent(source: nil)?.location ?? .zero
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)

        if CGGetDisplaysWithPoint(point, 16, &displays, &count) == .success, count > 0 {
            for index in 0..<Int(count) {
                if let transform = transform(for: displays[index]) { return transform }
            }
        }
        return transform(for: CGMainDisplayID())
    }
}
