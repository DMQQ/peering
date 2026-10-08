import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import MacCastKit
import RemoteCore
import ScreenCaptureKit
import os

/// A tile whose source has gone is left out of tiles rather than failing the plan: five pictures and a black rectangle beats a mosaic that never appears.
struct MosaicPlan: @unchecked Sendable {
    struct Tile: @unchecked Sendable {
        let source: CaptureSource
        let rect: CGRect
/// The tile's pixels in the canvas, never more than the source's own: the mosaic's cost control, since ScreenCaptureKit scales down for us.
        let pixelSize: CGSize
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
/// Drawn on first use when the tile has no picture: a stream that will not start or stopped before any frame. See MosaicPlaceholder/Card.
        let card: MosaicPlaceholder.Card
    }

/// Kept out of tiles because everything there assumes a capture: an engine, a held frame and a dead-set index each.
    struct Placeholder: @unchecked Sendable {
        let rect: CGRect
        let card: CIImage?
    }

    let canvas: CGSize
    let frameRate: Int
    let tiles: [Tile]
    let placeholders: [Placeholder]
}

extension MosaicPlan {
/// A tile whose source has gone stays on the canvas as a card: a window closed between the phone drawing the arrangement and the Mac building it is the ordinary start, not an error. Every tile gone is a mosaic with nothing in it, and the caller says so.
    static func make(
        layout: MosaicLayout,
        catalog: CaptureCatalog,
        resolver: CaptureSourceResolver
    ) -> MosaicPlan {
        var tiles: [Tile] = []
        var placeholders: [Placeholder] = []

        for tile in layout.tiles {
            let rect = tile.rect.pixels(in: layout.canvas)
            let descriptor = catalog.descriptor(for: tile.source)

            guard let descriptor,
                  let filterPlan = try? resolver.makeFilter(for: tile.source)
            else {
// In the arrangement but not the catalogue: nothing to capture. The card is built regardless, since the process table still knows the name and icon of an application with nothing open.
                placeholders.append(Placeholder(
                    rect: rect,
                    card: MosaicPlaceholder.image(
                        .missing(tile.source, descriptor: descriptor),
                        size: rect.size
                    )
                ))
                continue
            }

// The window's own shape contained in the tile, not each axis clamped separately (that gives a shape that is neither, and a picture where the phone does not expect it). See MosaicTileFit.
            guard let pixelSize = MosaicTileFit.surface(
                sourceSize: descriptor.pixelSize,
                tilePixels: rect
            ) else {
// No size on the source or tile: nothing to capture into, and the card says what the tile holds.
                placeholders.append(Placeholder(
                    rect: rect,
                    card: MosaicPlaceholder.image(.empty(descriptor: descriptor), size: rect.size)
                ))
                continue
            }

            guard let configuration = try? CaptureEngine.configuration(
                for: descriptor,
                pixelSize: pixelSize,
                frameRate: layout.frameRate,
// The pointer is drawn by ScreenCaptureKit per tile: a mosaic has N windows it can be in and no single screen rectangle.
                showsCursor: true
            ) else {
// A configuration ScreenCaptureKit will not accept is the same as a source it will not filter.
                placeholders.append(Placeholder(
                    rect: rect,
                    card: MosaicPlaceholder.image(.empty(descriptor: descriptor), size: rect.size)
                ))
                continue
            }

// The rectangle belongs to the filter, not the configuration. See CaptureFilterPlan.
            if let sourceRect = filterPlan.sourceRect {
                configuration.sourceRect = sourceRect
            }

            tiles.append(
                Tile(
                    source: tile.source,
                    rect: rect,
                    pixelSize: pixelSize,
                    filter: filterPlan.filter,
                    configuration: configuration,
                    card: MosaicPlaceholder.Card(
                        content: .empty(descriptor: descriptor),
                        size: rect.size
                    )
                )
            )
        }

        return MosaicPlan(
            canvas: layout.canvas,
            frameRate: layout.frameRate,
            tiles: tiles,
            placeholders: placeholders
        )
    }
}
