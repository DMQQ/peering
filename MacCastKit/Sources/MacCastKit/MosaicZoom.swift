import CoreGraphics
import RemoteCore

/// What a picture is multiplied by on its way to the screen, over and above the user's zoom.
public struct PictureScale: Equatable, Sendable {
    public let scalesToFill: Bool
    public let inset: CGFloat

    public init(scalesToFill: Bool, inset: CGFloat) {
        self.scalesToFill = scalesToFill
        self.inset = max(0, inset)
    }

    public func base(pixelSize: CGSize, in bounds: CGSize) -> CGFloat {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return 1 }
        guard scalesToFill else { return 1 - inset * 2 }

        let rect = CanvasGeometry.videoRect(bounds: bounds, pixelSize: pixelSize)
        guard rect.width > 0, rect.height > 0 else { return 1 }
        return max(bounds.width / rect.width, bounds.height / rect.height)
    }

    /// The same scale, about the middle of the screen, applied to a rectangle.
    public func scaled(_ rect: CGRect, in bounds: CGSize, by scale: CGFloat) -> CGRect {
        let centre = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        return CGRect(
            x: centre.x + (rect.minX - centre.x) * scale,
            y: centre.y + (rect.minY - centre.y) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }
}

/// The movement between an arrangement and one of its windows, in both directions.
public enum MosaicZoom {
    /// The zoom and the pan that turn one tile of the arrangement into that window on its own.
    public static func opening(
        layout: MosaicLayout,
        index: Int,
        sourceSize: CGSize?,
        bounds: CGSize,
        effectiveZoom: CGFloat,
        pan: CGSize,
        scale: PictureScale
    ) -> (zoom: CGFloat, pan: CGSize)? {
        guard bounds.width > 0, bounds.height > 0,
              layout.tiles.indices.contains(index),
              // No size, no movement. A source the catalogue cannot describe has no rectangle
              // inside it to aim at, and guessing, which is what asking `videoRect` for a size of
              // `nil` does, makes the destination the whole screen and the picture zooms until the
              // tile covers it: the overshoot this function exists to avoid.
              let sourceSize, sourceSize.width > 0, sourceSize.height > 0,
              effectiveZoom > 0
        else { return nil }

        let pictureSize = layout.canvas
        guard let tile = CanvasGeometry.rect(
            normalized: layout.tiles[index].rect,
            bounds: bounds, pixelSize: pictureSize,
            zoom: effectiveZoom, pan: pan
        ), let window = MosaicTileFit.windowRect(sourceSize: sourceSize, in: tile)
        else { return nil }

        let incoming = scale.base(pixelSize: sourceSize, in: bounds)
        let destination = scale.scaled(
            CanvasGeometry.videoRect(bounds: bounds, pixelSize: sourceSize),
            in: bounds,
            by: incoming
        )
        guard destination.width > 0, destination.height > 0 else { return nil }

        guard let target = CanvasGeometry.transform(
            of: window, mappingTo: destination,
            bounds: bounds, zoom: effectiveZoom, pan: pan
        ) else { return nil }

        let current = scale.base(pixelSize: pictureSize, in: bounds)
        guard current > 0 else { return nil }
        return (target.zoom / current, target.pan)
    }

    /// The zoom and the pan that draw a rectangle of a picture on a given rectangle of the screen.
    public static func placing(
        pixelSize: CGSize,
        anchor: NormalizedRect,
        at target: CGRect,
        bounds: CGSize,
        scale: PictureScale
    ) -> (zoom: CGFloat, pan: CGSize)? {
        guard bounds.width > 0, bounds.height > 0,
              pixelSize.width > 0, pixelSize.height > 0,
              target.width > 0, target.height > 0
        else { return nil }

        let base = scale.base(pixelSize: pixelSize, in: bounds)
        guard base > 0,
              let resting = CanvasGeometry.rect(
                  normalized: anchor, bounds: bounds, pixelSize: pixelSize,
                  zoom: 1, pan: .zero
              )
        else { return nil }

        let drawn = scale.scaled(resting, in: bounds, by: base)
        guard let placed = CanvasGeometry.transform(
            of: drawn, mappingTo: target,
            bounds: bounds, zoom: 1, pan: .zero
        ), placed.zoom > 0
        else { return nil }

        return (placed.zoom, placed.pan)
    }

    /// The same movement backwards: the window shrinking into the tile it will hold.
    public static func returning(
        layout: MosaicLayout,
        sourceID: String,
        sourceSize: CGSize?,
        bounds: CGSize,
        effectiveZoom: CGFloat,
        pan: CGSize,
        scale: PictureScale
    ) -> (zoom: CGFloat, pan: CGSize)? {
        guard bounds.width > 0, bounds.height > 0,
              layout.canvas.width > 0, layout.canvas.height > 0,
              let sourceSize, sourceSize.width > 0, sourceSize.height > 0,
              effectiveZoom > 0,
              let index = layout.tiles.firstIndex(where: { $0.source.stableID == sourceID })
        else { return nil }

        let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        guard let current = CanvasGeometry.rect(
            normalized: full, bounds: bounds, pixelSize: sourceSize,
            zoom: effectiveZoom, pan: pan
        ) else { return nil }

        let incoming = scale.base(pixelSize: layout.canvas, in: bounds)
        guard incoming > 0,
              let tile = CanvasGeometry.rect(
                  normalized: layout.tiles[index].rect,
                  bounds: bounds, pixelSize: layout.canvas,
                  zoom: incoming, pan: .zero
              ),
              let destination = MosaicTileFit.windowRect(sourceSize: sourceSize, in: tile)
        else { return nil }

        guard let target = CanvasGeometry.transform(
            of: current, mappingTo: destination,
            bounds: bounds, zoom: effectiveZoom, pan: pan
        ) else { return nil }

        let outgoing = scale.base(pixelSize: sourceSize, in: bounds)
        guard outgoing > 0 else { return nil }
        return (target.zoom / outgoing, target.pan)
    }
}
