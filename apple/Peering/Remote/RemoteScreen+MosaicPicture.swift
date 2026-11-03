import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

extension RemoteScreen {
    /// Drawn only while the mosaic is the picture, at rest, with no transition in flight.
    func mosaicTileRect(_ index: Int, in layout: MosaicLayout) -> CGRect? {
        guard layout.tiles.indices.contains(index) else { return nil }
        guard let tile = CanvasGeometry.rect(
            normalized: layout.tiles[index].rect,
            bounds: canvasSize,
            pixelSize: layout.canvas,
            zoom: effectiveZoom,
            pan: pan
        ) else { return nil }

        // The slot, not the window inside it: window-shaped frames make the grid read as a pile of rectangles.
        return tile
    }

    /// Anchored on the window, not the tile: a tile is mostly black, with the source letterboxed inside it.
    /// A stored zoom, a multiple of the picture's own base; `beginHeroTransition` converts it to a drawn scale.
    func tileOpeningTransform(_ index: Int, in layout: MosaicLayout) -> (zoom: CGFloat, pan: CGSize)? {
        guard layout.tiles.indices.contains(index) else { return nil }
        return MosaicZoom.opening(
            layout: layout,
            index: index,
            sourceSize: model.catalog?.descriptor(for: layout.tiles[index].source)?.pixelSize,
            bounds: canvasSize,
            effectiveZoom: effectiveZoom,
            pan: pan,
            scale: pictureScale
        )
    }

    /// The window is passed in because the ask writes the arrangement's id to `activeSourceID`, which would then match no tile.
    func mosaicReturnTransform(sourceID: String) -> (zoom: CGFloat, pan: CGSize)? {
        guard let layout = model.mosaicLayout else { return nil }
        return MosaicZoom.returning(
            layout: layout,
            sourceID: sourceID,
            sourceSize: model.capturePixelSize,
            bounds: canvasSize,
            effectiveZoom: effectiveZoom,
            pan: pan,
            scale: pictureScale
        )
    }

    /// The ask rather than the answer where both are the same arrangement, so a reorder lands under the finger (the Mac sends no new config for it). The answer where they differ.
    /// Nil while any transition is in flight, and when no arrangement is shown.
    var shownMosaicLayout: MosaicLayout? {
        guard transition == nil else { return nil }
        guard let arrived = model.pictureMosaicLayout else { return nil }
        guard model.isAskingForMosaic, let asked = model.askedMosaicLayout else { return arrived }
        return sameArrangement(asked, arrived) ? asked : arrived
    }

    /// `canReturnToMosaic` flips true before the window's first frame; gating on `transition == nil` stops Back freezing the mosaic crop instead of the window.
    var canReturnToMosaic: Bool {
        model.canReturnToMosaic && transition == nil
    }

    /// Deliberately not `==`: a reorder is a different layout and still the same picture.
    func sameArrangement(_ one: MosaicLayout, _ other: MosaicLayout) -> Bool {
        one.canvas == other.canvas
            && Set(one.tiles.map(\.source)) == Set(other.tiles.map(\.source))
    }

    /// Only this window of the frozen snapshot is shown: scaling the whole snapshot would move every other tile too.
    /// Nil except for the outward direction of a directional transition.
    var carriedWindow: CGRect? {
        guard let transition, let carry = transition.carry, carry.carriesOutOfArrangement else {
            return nil
        }
        return CanvasGeometry.rect(
            normalized: carry.frozenAnchor,
            bounds: canvasSize,
            pixelSize: carry.frozenSize,
            zoom: transition.zoom,
            pan: transition.pan
        )
    }

    /// Drawn rather than masked: masking a video layer renders the whole picture through alpha every frame, mid-animation.
    var carryingScrim: some View {
        ZStack {
            if let window = carriedWindow {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: canvasSize))
                    path.addRect(window)
                }
                .fill(Color.black, style: FillStyle(eoFill: true))
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
    }

    func windowAnchor(in layout: MosaicLayout, sourceID: String) -> NormalizedRect? {
        guard layout.canvas.width > 0, layout.canvas.height > 0,
              let index = layout.tiles.firstIndex(where: { $0.source.stableID == sourceID }),
              let size = model.catalog?.descriptor(for: layout.tiles[index].source)?.pixelSize,
              let window = MosaicTileFit.windowRect(
                  sourceSize: size,
                  in: layout.tiles[index].rect.pixels(in: layout.canvas)
              )
        else { return nil }

        return NormalizedRect(
            x: Double(window.minX / layout.canvas.width),
            y: Double(window.minY / layout.canvas.height),
            width: Double(window.width / layout.canvas.width),
            height: Double(window.height / layout.canvas.height)
        )
    }

    private func window(at slot: Int?, in layout: MosaicLayout) -> String? {
        guard let slot, layout.tiles.indices.contains(slot) else { return nil }
        return layout.tiles[slot].source.stableID
    }

    var mosaicOverlay: some View {
        // A `ZStack` and not a `Group`: a `Group` has no layout of its own, so a transition has nothing to attach to.
        ZStack {
            if let layout = shownMosaicLayout {
                MosaicOverlay(placed: layout.tiles.enumerated().compactMap { index, tile -> MosaicOverlay.Placed? in
                    guard let rect = mosaicTileRect(index, in: layout) else { return nil }
                    return MosaicOverlay.Placed(
                        // Keyed by window, not slot: a reorder moves windows between places, so by index nothing would animate.
                        id: tile.source.stableID,
                        rect: rect,
                        title: model.catalog?.descriptor(for: tile.source)?.title
                    )
                }, held: window(at: heldTile, in: layout),
                   heldPoint: heldPoint,
                   target: window(at: targetTile, in: layout))
                // Opacity only: a travelling line would spend the animation where the tile is not.
                // The way out is quicker: a tap has already started a hero transition, so lines still drawn would sit on a picture no longer there.
                .transition(.asymmetric(
                    insertion: .opacity.animation(Motion.settle),
                    removal: .opacity.animation(Motion.tap)
                ))
            }
        }
        .animation(Motion.settle, value: shownMosaicLayout != nil)
        .ignoresSafeArea()
    }

    /// Its own layer above the gesture surface: the borders take no touches.
    /// Only where the tile is big enough: on a small tile the button would take the tap meant for the window.
    var mosaicDismissButtons: some View {
        ZStack {
            if let layout = shownMosaicLayout, heldTile == nil {
                ForEach(layout.tiles.indices, id: \.self) { index in
                    if let rect = mosaicTileRect(index, in: layout),
                       rect.width > Self.dismissalMinimumTileWidth {
                        Button {
                            model.removeMosaicTile(at: index)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(ColorPalette.ink)
                                .frame(
                                    width: Self.dismissalDiameter,
                                    height: Self.dismissalDiameter
                                )
                                .glassSurface(in: Circle())
                        }
                        .contentShape(Circle())
                        .buttonStyle(RailButtonStyle(scale: 0.92))
                        .position(
                            x: rect.maxX - Self.dismissalInset - Self.dismissalDiameter / 2,
                            y: rect.minY + Self.dismissalInset + Self.dismissalDiameter / 2
                        )
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    private static let dismissalDiameter: CGFloat = 28

    private static let dismissalInset: CGFloat = 8

    private static let dismissalMinimumTileWidth: CGFloat = 140
}
