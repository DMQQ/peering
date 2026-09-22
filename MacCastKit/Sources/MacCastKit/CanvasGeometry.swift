import CoreGraphics
import RemoteCore

/// Where the video is actually drawn inside the canvas.
///
/// The layer letterboxes with `videoGravity = .resizeAspect`, so the picture occupies a
/// centred rect whose aspect matches the *captured pixels*. Every touch has to be mapped
/// through that rect, or the pointer lands proportionally wrong the moment the two aspects
/// differ — which on a phone showing a 16:10 Mac display is always.
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
    /// The gesture surface is a UIKit view and the chrome is drawn over it by SwiftUI, which is
    /// not enough to keep a touch on a button from reaching the Mac as well. A pan recogniser
    /// begins after ten points of travel, and a thumb pressing a button near the edge of the
    /// screen slides further than that without meaning to — so the drag starts on the surface
    /// underneath and the Mac's pointer jumps to wherever the finger happened to be, while the
    /// button it was aimed at also fires. There is nothing in the geometry to tell the two apart;
    /// the caller knows where its chrome is, so it says so.
    public static func isBlocked(_ point: CGPoint, regions: [CGRect]) -> Bool {
        regions.contains { $0.contains(point) }
    }

    /// Whether a tap should put something of ours away rather than reach the Mac.
    ///
    /// A panel and the software keyboard are the same thing from the picture's point of view:
    /// something of ours is open over it, and a tap on the picture belongs to closing that rather
    /// than to the Mac underneath. One decision asked twice with different answers for "is it
    /// open", rather than two functions that would drift apart at the first change.
    ///
    /// A pure decision for the same reason ``InteractionMode``'s routing is: a
    /// `UITapGestureRecognizer` cannot be driven from a unit test, and the whole of the behaviour
    /// is this one question. The chrome check is what keeps a tap *on* the panel from counting —
    /// a tap inside one belongs to the button under it, and dismissing on that would close the
    /// panel out from under the tile the user was aiming at.
    public static func dismissesOverlay(at point: CGPoint, regions: [CGRect], isOpen: Bool) -> Bool {
        isOpen && !isBlocked(point, regions: regions)
    }

    /// Turns a touch into a normalized position, undoing the canvas's zoom and pan first.
    ///
    /// Normalized — never pixels. The host maps the result through its own transform, which
    /// is the only side that knows where the captured content sits in the Mac's global
    /// coordinate space, and which changes under it when a window moves or a display is
    /// switched. A client that sent pixels would be wrong the first time either happened.
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
        // Clamped rather than rejected. A finger that slides off the edge of a letterboxed
        // picture has still expressed "as far as possible in that direction", and dropping
        // the sample would make the cursor stall at the boundary while the finger keeps
        // moving — which reads as a broken connection rather than as a limit.
        return NormalizedPoint(x: Double(min(max(x, 0), 1)), y: Double(min(max(y, 0), 1)))
    }

    /// The same mapping as ``point(normalized:bounds:pixelSize:zoom:pan:)``, for a rectangle.
    ///
    /// Two corners through that function rather than the arithmetic written out a second time.
    /// The zoom and the pan have to be applied to a rect exactly as they are to a point, and a
    /// second copy of the mapping is how the drawn tile borders and the drawn remote cursor come
    /// apart — one of them one zoom factor out from the picture, which is the kind of wrong that
    /// reads as a rendering bug rather than as a coordinate bug.
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
    /// **The mapping above, run backwards.** `rect` is somewhere on screen — a tile of a mosaic,
    /// as it happens — and the answer is what `zoom` and `pan` would have to become for that
    /// rectangle to land on `target`. It is the inverse of the same expression, in the same file,
    /// for the same reason ``rect(normalized:bounds:pixelSize:zoom:pan:)`` calls ``point`` rather
    /// than repeating its arithmetic: a version of this that was one sign out would send the
    /// picture the wrong way, and it would do it during the one movement in the app that is meant
    /// to explain what a tap did.
    ///
    /// **A target rectangle rather than "the screen", because the thing being moved is smaller
    /// than the screen it will end on.** Tapping a window in a mosaic should end with that window
    /// exactly where it will be when it is the whole picture — the same size, in the same place,
    /// so the moment the real stream arrives nothing moves — and that is a rectangle inside the
    /// screen, not the screen itself. Handing it `bounds` fills the screen instead, which is the
    /// right answer for the same call made about a rectangle that *is* the shape of a phone and
    /// the wrong one for a window.
    ///
    /// **The larger of the two ratios.** Where the two rectangles have the same shape the choice
    /// does not arise, and where they differ by a rounding — which is the ordinary case, since
    /// both come from the same aspect — taking the larger means the picture still covers what it
    /// is moving onto rather than leaving a hairline of the old one behind it.
    ///
    /// The result is a *drawn* scale, in the same terms `zoom` is used in by that function. A
    /// caller whose picture is drawn at some other scale than the value it stores — the app's Fill
    /// setting does exactly that — has to convert, and only it knows by how much.
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
