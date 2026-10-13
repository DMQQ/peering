import PeeringKit
import RemoteCore
import SwiftUI

struct MosaicOverlay: View {
    struct Placed: Identifiable, Equatable {
        /// **The window, not its place in the arrangement.** Two tiles of one arrangement are two
        /// windows in two rectangles, and a reorder is the same rectangles holding different
        /// windows — so an identity that is the *place* cannot tell the app that anything has
        /// happened, and the drawing has nothing to animate. Identified by the window, the outline
        /// being carried and the ones it displaces are all things that move. See
        /// ``RemoteScreen/dropHeldTile()``.
        let id: String
        let rect: CGRect
        let title: String?
    }

    let placed: [Placed]

    var held: String?
    var heldPoint: CGPoint?
    var target: String?

    private static let labelInset: CGFloat = 6

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(placed) { tile in
                let isHeld = tile.id == held
                let isTarget = tile.id == target && held != nil && target != held

                let drawn = isHeld ? (heldPoint.map { CGRect(
                    x: $0.x - tile.rect.width / 2,
                    y: $0.y - tile.rect.height / 2,
                    width: tile.rect.width,
                    height: tile.rect.height
                ) } ?? tile.rect) : tile.rect

                // **Corners are square, and rounded ones were a mistake worth naming.** These
                // lines are not the outlines of cards — they are where one window's picture stops
                // and the next one's begins, and the tiles share those edges. A corner radius on
                // each tile separately draws four little arcs wherever four tiles meet, which is
                // every interior junction in the arrangement: the grid looks like a tray of
                // buttons rather than a picture cut into six, and the corners have nothing to
                // round *against* on an edge that is shared.
                Rectangle()
                    .strokeBorder(
                        isTarget ? ColorPalette.accent : Color.white.opacity(isHeld ? 0.9 : 0.22),
                        lineWidth: isHeld || isTarget ? 2 : 1
                    )
                    .shadow(color: .black.opacity(isHeld ? 0.6 : 0), radius: isHeld ? 10 : 0)
                    .frame(width: max(drawn.width, 0), height: max(drawn.height, 0))
                    .position(x: drawn.midX, y: drawn.midY)

                if let title = tile.title, tile.rect.width > 120 {
                    // **A point, with the name drawn over it.** The name is given the width of its
                    // tile so a long one truncates where the tile ends. That is a *layout* claim,
                    // and a tile zoomed into is wider than the screen, so the claim grew with the
                    // canvas while the rectangles above are computed from the size the canvas ends
                    // up as: a `ZStack` is as big as its largest child, so the overlay grew the
                    // screen, the screen grew the gesture surface, and the surface reported a
                    // bigger canvas. Measured at 59 points a frame until it hit four thousand, for
                    // as long as anyone left it running. An overlay takes no part in layout, which
                    // is the same trick the source tiles use for their pictures.
                    Color.clear
                        .frame(width: 1, height: 1)
                        .overlay(alignment: .topLeading) {
                            Text(title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.45), in: Capsule())
                                .frame(
                                    width: max(drawn.width - Self.labelInset * 2, 0),
                                    alignment: .leading
                                )
                        }
                        .offset(x: drawn.minX + Self.labelInset, y: drawn.minY + Self.labelInset)
                }
            }
        }
        // **Nothing here claims a size.** Every child below is either positioned, which fills, or
        // drawn over a one-point anchor, so this reports the space it is given and cannot be the
        // reason the screen it lives on got bigger. Sizing it from the canvas instead was tried and
        // is what set the loop off: the canvas is the size this view ends up as.
        .allowsHitTesting(false)
    }
}
