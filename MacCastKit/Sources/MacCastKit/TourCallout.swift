import CoreGraphics

/// Where a tour's card goes: the rectangle it occupies, and where its caret points.
///
/// **Arithmetic rather than a layout, and it has to be.** The card is drawn over a dimmed app at a
/// position that depends on where the control under it happens to be, and that position is known
/// only once the control has been laid out and measured. A stack could not do this: a `VStack`
/// puts one thing under another and this card is under *one* control that may be anywhere, with
/// the rest of the screen the only thing it must stay out of. So the frame is computed from the
/// two rectangles and the card is placed at it.
///
/// It lives here, and not in the view that draws it, because it is the rule the tour's whole
/// usability rests on: the card may not cover the control it is describing, and it may not run off
/// the screen. Written as an expression over four numbers it can be tested for every arrangement
/// of them; written inline in a `body` it could only be looked at.
public struct TourCallout: Equatable, Sendable {
    /// Which edge of the card the caret is on, and so which way it points.
    public enum Edge: Equatable, Sendable {
        /// The card is under the control and the caret sits on its top edge.
        case below
        /// The card is over the control and the caret sits on its bottom edge.
        case above
    }

    /// Where the card goes, in the tour's own coordinates.
    public let frame: CGRect
    public let caretEdge: Edge
    /// The caret's centre along the card's width, in the same coordinates as ``frame``.
    public let caretX: CGFloat

    /// The card's width, which is the same on every step so that a tour does not change shape as
    /// it is read.
    ///
    /// Capped, because a card as wide as a landscape phone is a paragraph the eye has to travel
    /// across; and short of the screen's own edges, because a card touching both of them reads as a
    /// panel that arrived from somewhere rather than as a thing floating over the control.
    public static let maximumWidth: CGFloat = 340

    public static func cardWidth(in bounds: CGSize, margin: CGFloat = 16) -> CGFloat {
        max(0, min(maximumWidth, bounds.width - margin * 2))
    }

    /// Puts the card under the control it describes, or over it when there is no room under.
    ///
    /// Under first, always. The control is what the person is looking at, and a card arriving above
    /// it lands on the line they are reading; below it is the direction the screen's own content
    /// continues in, and the eye has already travelled that way once.
    ///
    /// - Parameters:
    ///   - hole: the lit rectangle: the control, plus whatever margin the ring around it keeps.
    ///   - cardSize: the card's measured size. Measured rather than assumed, because the sentence
    ///     in it is two lines on one phone and three on another.
    ///   - gap: from the hole's edge to the card's, which has to clear the caret the card wears.
    public static func placement(
        hole: CGRect,
        cardSize: CGSize,
        in bounds: CGSize,
        gap: CGFloat = 20,
        margin: CGFloat = 16,
        caretInset: CGFloat = 22
    ) -> TourCallout {
        let below = hole.maxY + gap
        let above = hole.minY - gap - cardSize.height
        let roomBelow = bounds.height - margin - below
        let roomAbove = hole.minY - gap - margin

        let edge: Edge
        let y: CGFloat
        if roomBelow >= cardSize.height {
            edge = .below
            y = below
        } else if roomAbove >= cardSize.height {
            edge = .above
            y = above
        } else {
            // Nowhere it fits whole, so it goes to the far end of the screen from the control and
            // takes whatever overlap that costs. Two ends of a small phone is all the room there
            // is, and putting it at the end the control is *not* at is the arrangement that leaves
            // as much of that control visible as the screen allows. This is a landscape phone with
            // the keyboard up, or a small screen in a very cramped state; it is not the ordinary
            // case, and it is the only one that can overlap.
            edge = hole.midY > bounds.height / 2 ? .above : .below
            y = edge == .above ? margin : bounds.height - margin - cardSize.height
        }

        // Clamped into the screen, which is what keeps a card half the height of a phone from
        // running off the bottom of one. The upper bound can be below the lower one when the card
        // is taller than the space there is; the margin wins, and the card is cut off rather than
        // pushed off.
        let top = min(max(y, margin), max(margin, bounds.height - margin - cardSize.height))
        let left = min(
            max(hole.midX - cardSize.width / 2, margin),
            max(margin, bounds.width - margin - cardSize.width)
        )
        let frame = CGRect(origin: CGPoint(x: left, y: top), size: cardSize)

        // The caret points at the control's centre, and stays on the card. A control near the edge
        // of the screen pushes the card inwards until the carets would be off its corner, and a
        // caret hanging past the rounded corner is a mark on nothing at all.
        let widest = frame.maxX - caretInset
        let narrowest = frame.minX + caretInset
        let caretX = narrowest <= widest
            ? min(max(hole.midX, narrowest), widest)
            : frame.midX

        return TourCallout(frame: frame, caretEdge: edge, caretX: caretX)
    }
}
