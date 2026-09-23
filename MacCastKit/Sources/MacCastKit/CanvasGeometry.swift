import CoreGraphics
import RemoteCore

/// Where the video is actually drawn inside the canvas.
///
/// The layer letterboxes with `videoGravity = .resizeAspect`, so the picture occupies a
/// centred rect whose aspect matches the captured pixels. Every touch has to be mapped through
/// that rect, or the pointer lands proportionally wrong when the two aspects differ.
public enum CanvasGeometry {
    /// The layer's letterboxed rect for a captured size, inside `bounds`.
    public static func videoRect(bounds: CGSize, pixelSize: CGSize?) -> CGRect {
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0,
              bounds.width > 0, bounds.height > 0
        else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / pixelSize.width, bounds.height / pixelSize.height)
        let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Whether a touch belongs to the window's own chrome rather than to the Mac.
    ///
    /// The chrome is drawn over the gesture surface by SwiftUI, which does not stop a touch on a
    /// button from also reaching the Mac, and there is nothing in the geometry to tell the two
    /// apart.
    public static func isBlocked(_ point: CGPoint, regions: [CGRect]) -> Bool {
        regions.contains { $0.contains(point) }
    }

    /// Whether a tap should put something of ours away rather than reach the Mac.
    ///
    /// A panel and the software keyboard are the same thing from the picture's point of view:
    /// something of ours is open over it, and a tap on the picture belongs to closing that rather
    /// than to the Mac underneath.
    ///
    /// A pure decision, so it can be tested without a `UITapGestureRecognizer`. The chrome check
    /// keeps a tap on the panel itself from counting: it belongs to the button under it.
    public static func dismissesOverlay(at point: CGPoint, regions: [CGRect], isOpen: Bool) -> Bool {
        isOpen && !isBlocked(point, regions: regions)
    }

    /// Turns a touch into a normalized position, undoing the canvas's zoom and pan first.
    ///
    /// Normalized, never pixels: the host maps the result through its own transform, the only
    /// side that knows where the captured content sits in the Mac's global coordinate space.
    public static func normalized(
        point: CGPoint,
        bounds: CGSize,
        pixelSize: CGSize?,
        zoom: CGFloat,
        pan: CGSize
    ) -> NormalizedPoint? {
        guard bounds.width > 0, bounds.height > 0, zoom > 0 else { return nil }
        let rect = videoRect(bounds: bounds, pixelSize: pixelSize)
        guard rect.width > 0, rect.height > 0 else { return nil }

        let centre = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        let content = CGPoint(
            x: (point.x - centre.x - pan.width) / zoom + centre.x,
            y: (point.y - centre.y - pan.height) / zoom + centre.y
        )

        let x = (content.x - rect.minX) / rect.width
        let y = (content.y - rect.minY) / rect.height
        // Clamped rather than rejected: a finger that slides off the edge of a letterboxed
        // picture has still expressed "as far as possible in that direction", and dropping the
        // sample would stall the cursor at the boundary while the finger keeps moving.
        return NormalizedPoint(x: Double(min(max(x, 0), 1)), y: Double(min(max(y, 0), 1)))
    }

    /// The same mapping as ``point(normalized:bounds:pixelSize:zoom:pan:)``, for a rectangle.
    ///
    /// Two corners through that function rather than the arithmetic written out a second time, so
    /// the drawn tile borders and the drawn remote cursor cannot come apart.
    public static func rect(
        normalized: NormalizedRect,
        bounds: CGSize,
        pixelSize: CGSize?,
        zoom: CGFloat,
        pan: CGSize
    ) -> CGRect? {
        let rect = normalized.clamped
        guard let topLeft = point(
            normalized: NormalizedPoint(x: rect.x, y: rect.y),
            bounds: bounds, pixelSize: pixelSize, zoom: zoom, pan: pan
        ), let bottomRight = point(
            normalized: NormalizedPoint(x: rect.x + rect.width, y: rect.y + rect.height),
            bounds: bounds, pixelSize: pixelSize, zoom: zoom, pan: pan
        ) else { return nil }

        return CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }

    /// Places a normalized remote pointer back into the exact canvas coordinate space used by
    /// ``normalized(point:bounds:pixelSize:zoom:pan:)``.
    public static func point(
        normalized: NormalizedPoint,
        bounds: CGSize,
        pixelSize: CGSize?,
        zoom: CGFloat,
        pan: CGSize
    ) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0, zoom > 0 else { return nil }
        let rect = videoRect(bounds: bounds, pixelSize: pixelSize)
        guard rect.width > 0, rect.height > 0 else { return nil }

        let content = CGPoint(
            x: rect.minX + CGFloat(normalized.x) * rect.width,
            y: rect.minY + CGFloat(normalized.y) * rect.height
        )
        let centre = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        return CGPoint(
            x: (content.x - centre.x) * zoom + centre.x + pan.width,
            y: (content.y - centre.y) * zoom + centre.y + pan.height
        )
    }

    /// The zoom and the pan that move one rectangle of the picture onto another.
    ///
    /// The mapping above, run backwards: `rect` is somewhere on screen, and the answer is what
    /// `zoom` and `pan` would have to become for that rectangle to land on `target`.
    ///
    /// A target rectangle rather than the screen: tapping a window in a mosaic should end with that
    /// window exactly where it will be when it is the whole picture, so the moment the real stream
    /// arrives nothing moves. Handing it `bounds` fills the screen instead.
    ///
    /// The larger of the two ratios, so rectangles differing by a rounding still cover the target.
    ///
    /// The result is a drawn scale, in the same terms `zoom` is used in by that function: a caller
    /// whose picture is drawn at another scale, as the app's Fill setting does, has to convert.
    ///
    /// `nil` when there is nothing to work with: no rectangle, no screen, no target, or a zoom of
    /// zero, which has no inverse.
    public static func transform(
        of rect: CGRect,
        mappingTo target: CGRect,
        bounds: CGSize,
        zoom: CGFloat,
        pan: CGSize
    ) -> (zoom: CGFloat, pan: CGSize)? {
        guard bounds.width > 0, bounds.height > 0,
              rect.width > 0, rect.height > 0,
              target.width > 0, target.height > 0,
              zoom > 0
        else { return nil }

        let centre = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        // The rectangle in the picture's own coordinates: ``point(normalized:bounds:pixelSize:zoom:pan:)``
        // solved for its input.
        let content = CGRect(
            x: (rect.minX - centre.x - pan.width) / zoom + centre.x,
            y: (rect.minY - centre.y - pan.height) / zoom + centre.y,
            width: rect.width / zoom,
            height: rect.height / zoom
        )

        let scale = max(target.width / content.width, target.height / content.height)
        return (
            scale,
            CGSize(
                width: target.midX - centre.x - (content.midX - centre.x) * scale,
                height: target.midY - centre.y - (content.midY - centre.y) * scale
            )
        )
    }
}
