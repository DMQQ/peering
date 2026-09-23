import CoreGraphics
import Foundation

/// A position in the captured image, normalized to `0…1` on each axis.
///
/// Normalized coordinates are what make the client resolution- and Retina-independent, and what
/// survive the host switching to a display of a different size mid-session.
public struct NormalizedPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// Clamped copy: the client canvas can overscroll during a gesture, and a value outside the
    /// image must not drive the host cursor off-screen.
    public var clamped: NormalizedPoint {
        NormalizedPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}

/// Maps normalized client coordinates onto the global coordinate space the host injects into.
///
/// Unlike a display (fixed origin, stable size), an application or window moves and resizes, and
/// its content rect is reported in points within the capture surface, so the transform is rebuilt
/// whenever a frame reports a changed content rect.
///
/// `origin` is the top-left of the captured content in global display points, the space `CGEvent`
/// posts into: (0,0) is the primary display's top-left, y increases downward, and a display to the
/// left or above the primary has a negative origin.
public struct InputTransform: Equatable, Sendable {
    /// Top-left of captured content in global display points.
    public let origin: CGPoint
    /// Size of the captured content in pixels.
    public let pixelSize: CGSize
    /// Backing scale of the captured content. 2.0 on a Retina display.
    public let pointPixelScale: CGFloat

    public init(origin: CGPoint, pixelSize: CGSize, pointPixelScale: CGFloat) {
        self.origin = origin
        self.pixelSize = pixelSize
        self.pointPixelScale = pointPixelScale
    }

    /// A display's transform: origin in points, size in pixels, at the given scale.
    public static func display(
        origin: CGPoint,
        pixelSize: CGSize,
        pointPixelScale: CGFloat
    ) -> InputTransform {
        InputTransform(origin: origin, pixelSize: pixelSize, pointPixelScale: pointPixelScale)
    }

    /// Converts a normalized position into a global point ready for `CGEvent`.
    ///
    /// Normalized space is not aspect-corrected: (0,0) is the top-left of the captured content and
    /// (1,1) the bottom-right, whatever the aspect ratio. The client letterboxes that onto its canvas.
    public func globalPoint(fromNormalized point: NormalizedPoint) -> CGPoint {
        let p = point.clamped
        let pixelX = CGFloat(p.x) * pixelSize.width
        let pixelY = CGFloat(p.y) * pixelSize.height
        let scale = pointPixelScale > 0 ? pointPixelScale : 1
        return CGPoint(x: origin.x + pixelX / scale, y: origin.y + pixelY / scale)
    }

    /// Inverse of ``globalPoint(fromNormalized:)``, used by the host to report the cursor position.
    public func normalizedPoint(fromGlobal point: CGPoint) -> NormalizedPoint {
        let scale = pointPixelScale > 0 ? pointPixelScale : 1
        let pixelX = (point.x - origin.x) * scale
        let pixelY = (point.y - origin.y) * scale
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            return NormalizedPoint(x: 0, y: 0)
        }
        return NormalizedPoint(
            x: Double(pixelX / pixelSize.width),
            y: Double(pixelY / pixelSize.height)
        )
    }
}
