import CoreGraphics

/// Where a tour's card goes and where its caret points. The card may neither cover the control nor leave the screen.
public struct TourCallout: Equatable, Sendable {
    public enum Edge: Equatable, Sendable {
        case below
        case above
    }

    public let frame: CGRect
    public let caretEdge: Edge
    public let caretX: CGFloat

    /// Same width on every step, capped so the card is never a paragraph.
    public static let maximumWidth: CGFloat = 340

    public static func cardWidth(in bounds: CGSize, margin: CGFloat = 16) -> CGFloat {
        max(0, min(maximumWidth, bounds.width - margin * 2))
    }

    /// Under the control first, since a card above it lands on the line being read; over it when there is no room.
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
            // No room either side: go to the far end from the control, overlapping as little as possible (landscape with the keyboard up).
            edge = hole.midY > bounds.height / 2 ? .above : .below
            y = edge == .above ? margin : bounds.height - margin - cardSize.height
        }

        // Clamped into the screen; a card taller than the space is cut off rather than pushed off.
        let top = min(max(y, margin), max(margin, bounds.height - margin - cardSize.height))
        let left = min(
            max(hole.midX - cardSize.width / 2, margin),
            max(margin, bounds.width - margin - cardSize.width)
        )
        let frame = CGRect(origin: CGPoint(x: left, y: top), size: cardSize)

        let widest = frame.maxX - caretInset
        let narrowest = frame.minX + caretInset
        let caretX = narrowest <= widest
            ? min(max(hole.midX, narrowest), widest)
            : frame.midX

        return TourCallout(frame: frame, caretEdge: edge, caretX: caretX)
    }
}
