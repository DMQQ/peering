import MacCastKit
import StoreKit
import SwiftUI

struct PlanCard: View {
    let tier: StoreManager.Tier
    let price: String?
    let note: String?
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 10) {
                if tier.isRecommended {
                    Text("Best value")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(ColorPalette.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(ColorPalette.accent.opacity(0.18), in: Capsule())
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(tier.name)
                        .font(DisplayFont.display(21))
                        .tracking(-0.5)
                        .foregroundStyle(ColorPalette.ink)

                    Text(price ?? "···")
                        .font(DisplayFont.display(26))
                        .tracking(-0.8)
                        .foregroundStyle(ColorPalette.ink)

                    if let note {
                        Text(note)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(ColorPalette.accent)
                            .padding(.top, 2)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tier.features, id: \.self) { feature in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(ColorPalette.ink.opacity(0.45))
                                .frame(width: 10, alignment: .leading)

                            Text(feature)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
            // Take the whole sheet width before drawing the surface. Expanding after
            // `cardSurface()` would leave the visible card hugging its longest line of text.
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(ColorPalette.accent, lineWidth: 1.5)
                    .opacity(selected ? 1 : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(RailButtonStyle(scale: 0.985))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - Shared picker
