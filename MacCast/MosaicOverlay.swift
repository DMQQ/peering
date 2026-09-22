import MacCastKit
import RemoteCore
import SwiftUI

/// The edges and names of the tiles, drawn over a picture the Mac has already composited.
///
/// **Nothing here is the picture.** The Mac draws the canvas; this draws where one window ends
/// and the next begins, which is the difference between a user seeing several windows and a user
/// seeing one strange arrangement of things. It is drawn as an overlay rather than as chrome and
/// it takes no touches at all: a tap on a tile is routed by the gesture surface, which is the
/// only layer that knows both where the picture is on screen and what is over it. An overlay that
/// answered touches would have to know the same thing twice.
///
/// The rectangles arrive already mapped into the view's coordinates — through the same
/// ``CanvasGeometry`` call the drawn remote cursor goes through, so the borders and the cursor
/// cannot disagree about where the picture is — which keeps this a drawing and nothing else.
struct MosaicOverlay: View {
    /// One tile, where it is on screen and what to call it.
    struct Placed: Identifiable, Equatable {
        let id: Int
        let rect: CGRect
        let title: String?
    }

    let placed: [Placed]

    /// How far the name sits from its tile's corner.
    private static let labelInset: CGFloat = 6

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(placed) { tile in
                // An outline rather than a fill: a filled tint over live video would tint the
                // thing the user is trying to read, and the picture inside a tile is the whole
                // point of the tile.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                    .frame(width: max(tile.rect.width, 0), height: max(tile.rect.height, 0))
                    .position(x: tile.rect.midX, y: tile.rect.midY)

                if let title = tile.title, tile.rect.width > 120 {
                    // Named only where there is room for a name. A tile smaller than this is a
                    // label with a window behind it, and the user picked these windows knowing
                    // which was which.
                    //
                    // Offset from the canvas's own top-left rather than positioned by its
                    // centre: the label belongs to the tile's corner, and its width is whatever
                    // the window's name happens to be, so centring it would make it move when
                    // the text did.
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.45), in: Capsule())
                        .frame(width: max(tile.rect.width - Self.labelInset * 2, 0), alignment: .leading)
                        .offset(x: tile.rect.minX + Self.labelInset, y: tile.rect.minY + Self.labelInset)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
