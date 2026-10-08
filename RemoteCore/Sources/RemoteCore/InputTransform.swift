import CoreGraphics
import Foundation

/// Normalized so the client is resolution-independent and survives the host switching display size.
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

/// An application or window moves and resizes, so the transform is rebuilt whenever a frame reports a changed content rect.
/// `origin` is the top-left of the captured content in global display points, the space `CGEvent`
/// posts into: (0,0) is the primary display's top-left, y increases downward, and a display to the
/// left or above the primary has a negative origin.
public struct InputTransform: Equatable, Sendable {
    public let origin: CGPoint
    public let pixelSize: CGSize
    public let pointPixelScale: CGFloat

    public init(origin: CGPoint, pixelSize: CGSize, pointPixelScale: CGFloat) {
        self.origin = origin
        self.pixelSize = pixelSize
        self.pointPixelScale = pointPixelScale
    }

    public static func display(
        origin: CGPoint,
        pixelSize: CGSize,
        pointPixelScale: CGFloat
    ) -> InputTransform {
        InputTransform(origin: origin, pixelSize: pixelSize, pointPixelScale: pointPixelScale)
    }

    /// Not aspect-corrected: (0,0) is top-left and (1,1) bottom-right whatever the aspect ratio.
    public func globalPoint(fromNormalized point: NormalizedPoint) -> CGPoint {
        let p = point.clamped
        let pixelX = CGFloat(p.x) * pixelSize.width
        let pixelY = CGFloat(p.y) * pixelSize.height
        let scale = pointPixelScale > 0 ? pointPixelScale : 1
        return CGPoint(x: origin.x + pixelX / scale, y: origin.y + pixelY / scale)
    }

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
