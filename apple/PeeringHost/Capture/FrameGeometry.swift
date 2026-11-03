import CoreGraphics
import Foundation
import RemoteCore

/// A window or application filter composites onto a surface that is not the content; the content rect moves with no notification when the user drags or resizes, so it travels with the frame.
struct FrameGeometry: Sendable, Equatable {
    let contentRect: CGRect?
    let contentScale: CGFloat?
    let scaleFactor: CGFloat?
    /// Where the content is on screen, in global points, the space `CGEvent` posts into.
    let screenRect: CGRect?
}

extension FrameGeometry {
/// Built from `screenRect` (global points, the space `CGEvent` posts into), not `contentRect`. `scaleFactor` belongs to the display, so it is also the `pointPixelScale`, as in ``DisplayGeometry``.
    var inputTransform: InputTransform? {
        guard let screenRect, screenRect.width > 0, screenRect.height > 0,
              let scaleFactor, scaleFactor > 0
        else { return nil }

        return InputTransform(
            origin: screenRect.origin,
            pixelSize: CGSize(
                width: screenRect.width * scaleFactor,
                height: screenRect.height * scaleFactor
            ),
            pointPixelScale: scaleFactor
        )
    }
}
