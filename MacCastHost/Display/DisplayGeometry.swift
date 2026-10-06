import CoreGraphics
import Foundation
import RemoteCore

enum DisplayGeometry {
/// CGDisplayBounds is in points and CGDisplayPixelsWide in pixels; the backing scale is not always 2.
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

/// Falls back to the main display when the query fails.
    static func pointerDisplayIDs() -> [CGDirectDisplayID] {
        let point = CGEvent(source: nil)?.location ?? .zero
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)

        guard CGGetDisplaysWithPoint(point, 16, &displays, &count) == .success, count > 0 else {
            return [CGMainDisplayID()]
        }
        return Array(displays.prefix(Int(count)))
    }

/// Main is not the active display on a multi-display Mac.
    static func pointerDisplayID() -> CGDirectDisplayID {
        pointerDisplayIDs().first ?? CGMainDisplayID()
    }

    static func activeTransform() -> InputTransform? {
        for display in pointerDisplayIDs() {
            if let transform = transform(for: display) { return transform }
        }
        return transform(for: CGMainDisplayID())
    }
}
