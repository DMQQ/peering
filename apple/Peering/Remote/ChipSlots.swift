import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

/// A flat fill rather than a material: the chips sit inside the pill's own glass.
/// No selected state: the accent means "this one is on" elsewhere, and a blue chip read as another kind of control.
extension View {
    @ViewBuilder
    func pillChip(
        filling: Bool = false,
        destructive: Bool = false
    ) -> some View {
        let chip = self
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 7)
            .frame(height: 28)
            .frame(maxWidth: filling ? .infinity : nil)

        // The plain chip's colour is the caller's: the secondary grey made a row of controls read as switched off.
        if destructive {
            chip
                // A filled chip carries the palette's `onInk`: white on the red is unreadable.
                .foregroundStyle(ColorPalette.onInk)
                .background(ColorPalette.danger, in: Capsule())
        } else {
            chip.background(.primary.opacity(0.08), in: Capsule())
        }
    }
}

/// Equal slots, not a flow: a flow gave every chip its own width and rows ended ragged. Words are chosen to fit the slot.
struct ChipSlots: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let count = subviews.count
        guard count > 0 else { return .zero }
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        guard let width = proposal.width else {
            let natural = subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width }
            return CGSize(width: natural + spacing * CGFloat(count - 1), height: height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let count = CGFloat(subviews.count)
        guard count > 0 else { return }
        let slot = (bounds.width - spacing * (count - 1)) / count
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + (slot + spacing) * CGFloat(index), y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: slot, height: bounds.height)
            )
        }
    }
}
