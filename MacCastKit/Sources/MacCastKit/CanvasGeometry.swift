import CoreGraphics
import RemoteCore

/// Where the video is actually drawn inside the canvas.
public enum CanvasGeometry {
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
    public static func isBlocked(_ point: CGPoint, regions: [CGRect]) -> Bool {
        regions.contains { $0.contains(point) }
    }

    /// Turns a touch into a normalized position, undoing the canvas's zoom and pan first.
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
        return NormalizedPoint(x: Double(min(max(x, 0), 1)), y: Double(min(max(y, 0), 1)))
    }

    /// The same mapping as ``point(normalized:bounds:pixelSize:zoom:pan:)``, for a rectangle.
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
