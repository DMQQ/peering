import StoreKit
import SwiftUI

/// (Where the screen offers it) Free, then Pro monthly and Lifetime as one-line rows. Pro's two benefits are written once in the Monthly row's note, since repeating them per plan made the choice look like a choice between feature lists.
struct PlanOfferCards: View {
    @Environment(StoreManager.self) private var store
    @Binding var selection: PlanOffer?
    var includesFree = false

    var body: some View {
        VStack(spacing: 10) {
            if includesFree {
                row(
                    nil,
                    title: String(localized: "Free"),
                    note: OnboardingView.freeLine,
                    price: nil,
                    caption: nil
                )
            }
            if let monthly = store.product(for: .subscription) {
                row(
                    .subscription,
                    title: String(localized: "Pro"),
                    note: String(localized: "Unlimited time away, the sharpest relay picture"),
                    price: monthly.displayPrice,
                    caption: String(localized: "per month")
                )
            }
            if let lifetime = store.product(for: .lifetime) {
                row(
                    .lifetime,
                    title: String(localized: "Lifetime"),
                    note: String(localized: "Everything in Pro, paid once"),
                    price: lifetime.displayPrice,
                    caption: String(localized: "one time"),
                    badge: String(localized: "Best value")
                )
            }
        }
        .animation(Motion.tap, value: selection)
    }

    private func row(_ offer: PlanOffer?, title: String, note: String, price: String?, caption: String?, badge: String? = nil) -> some View {
        let isSelected = selection == offer
        return Button { selection = offer } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? ColorPalette.accent : ColorPalette.ink.opacity(0.3))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ColorPalette.ink)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(ColorPalette.onInk)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(ColorPalette.ink, in: Capsule())
                        }
                    }
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if let price, let caption {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(price)
                            .font(DisplayFont.display(22))
                            .tracking(-0.6)
                            .foregroundStyle(ColorPalette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(caption)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(ColorPalette.accent, lineWidth: 1.5)
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(RailButtonStyle(scale: 0.985))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
