import MacCastKit
import StoreKit
import SwiftUI
import UIKit

extension OnboardingView {
    @ViewBuilder
    var plans: some View {
        if store.isPro {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(ColorPalette.accent)

                Text("You are on Pro")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(ColorPalette.ink)

                Text("Every Mac, relay without a limit, and every update from here on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if store.products.isEmpty {
            VStack(spacing: 12) {
                ProgressView().tint(ColorPalette.ink)
                Text(store.productsUnavailable
                     ? "The App Store could not be reached. You can choose a plan later in Settings."
                     : "Loading plans…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(spacing: 10) {
                BillingPeriodPicker(period: $period, saving: store.smallestYearlySaving)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        PlanChoice(
                            name: String(localized: "Free"),
                            line: Self.freeLine,
                            price: String(localized: "No charge"),
                            recommended: false,
                            selected: chosen == nil,
                            select: { chosen = nil }
                        )

                        ForEach(StoreManager.Tier.allCases) { tier in
                            PlanChoice(
                                name: tier.name,
                                line: tier.tagline,
                                price: store.priceLabel(for: tier, period: period) ?? "···",
                                recommended: tier.isRecommended,
                                selected: chosen == tier,
                                features: tier.features,
                                select: { chosen = tier }
                            )
                        }
                    }
                    .animation(Motion.tap, value: chosen)
                    .animation(Motion.tap, value: period)
                }
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.25), location: 0),
                            .init(color: .black, location: 0.025),
                            .init(color: .black, location: 0.95),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        }
    }
}
