import MacCastKit
import StoreKit
import SwiftUI
import UIKit

extension OnboardingView {
    /// The three plans, as compactly as they can be told apart.
    ///
    /// Rows rather than cards with the full feature lists, because this is not the screen that
    /// sells them — it is the page that says there is something to decide before the introduction
    /// is over, at the one moment the user has just been told what the app does. The comparison is
    /// one tap away and is where the detail belongs; a page of three feature lists inside a swipe
    /// is a page nobody reads, on a screen that is trying to be finished with.
    @ViewBuilder
    var plans: some View {
        if store.isPro {
            // Somebody who has already paid, looking at the tour again from Settings. There is
            // nothing to sell them, so the page states rather than asks.
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
                        // Free first, because it is the floor the other three are measured from
                        // rather than a fourth thing on offer.
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
                // Three plans with their feature lists are taller than the room the page leaves
                // them, so the list is cut at both ends of the scroll. A hard cut through the
                // middle of a card reads as a card that has been sliced, which is the one thing a
                // list that is scrollable should never look like. The last few points fade into
                // the backdrop instead, and the same at the top, where the cards pass under the
                // switch.
                //
                // A mask rather than a gradient drawn over the ends: the page already sits on
                // ``ColorPalette/backdrop``, so fading the content out is fading it to the colour
                // that is already there, and nothing here has to know what that colour is.
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
