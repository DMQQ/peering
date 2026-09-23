import CoreGraphics

/// Where a tour's card goes: the rectangle it occupies, and where its caret points.
///
/// Arithmetic rather than a layout: the position depends on where the control under the card
/// happens to be, known only once it has been laid out and measured. The card may not cover that
/// control and may not run off the screen.
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

    /// The card's width, the same on every step so that a tour does not change shape as it is read.
    ///
    /// Capped, so a card is never a paragraph the eye has to travel across.
    public static let maximumWidth: CGFloat = 340

    public static func cardWidth(in bounds: CGSize, margin: CGFloat = 16) -> CGFloat {
        max(0, min(maximumWidth, bounds.width - margin * 2))
    }

    /// Puts the card under the control it describes, or over it when there is no room under.
    ///
    /// Under first, always: the control is what the person is looking at, and a card arriving above
    /// it lands on the line they are reading.
    ///
    /// - Parameters:
    ///   - hole: the lit rectangle: the control, plus whatever margin the ring around it keeps.
    ///   - cardSize: the card's measured size, which is two lines on one phone and three on another.
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
            // takes whatever overlap that costs, which leaves the most of the control visible. It is
            // the only case that can overlap: a landscape phone with the keyboard up.
            edge = hole.midY > bounds.height / 2 ? .above : .below
            y = edge == .above ? margin : bounds.height - margin - cardSize.height
        }

        // Clamped into the screen, which is what keeps a tall card from running off the bottom of
        // one. When the card is taller than the space there is, the margin wins and the card is cut
        // off rather than pushed off.
        let top = min(max(y, margin), max(margin, bounds.height - margin - cardSize.height))
        let left = min(
            max(hole.midX - cardSize.width / 2, margin),
            max(margin, bounds.width - margin - cardSize.width)
        )
        let frame = CGRect(origin: CGPoint(x: left, y: top), size: cardSize)

        // The caret points at the control's centre and stays on the card: one hanging past the
        // rounded corner is a mark on nothing at all.
        let widest = frame.maxX - caretInset
        let narrowest = frame.minX + caretInset
        let caretX = narrowest <= widest
            ? min(max(hole.midX, narrowest), widest)
            : frame.midX

        return TourCallout(frame: frame, caretEdge: edge, caretX: caretX)
    }
}
