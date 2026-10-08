import MacCastKit
import StoreKit
import SwiftUI

extension PaywallView {
    var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "network")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(ColorPalette.ink)
                .frame(height: 56)

            VStack(alignment: .leading, spacing: 8) {
                Text(reason.title)
                    .font(DisplayFont.display(28))
                    .tracking(-1)

                // **The plan the app states, not the plan it tells the relay.** `relayPlan` is free
                // for anybody with no receipt, which is a developer plan override or the moment
                // before StoreKit answers, so reading it here put free-plan copy under a screen whose own
                // cards said Pro. See the note on the quota event in ``MacSession``.
                Text(reason.detail(for: store.access.plan ?? .free))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                remainingMeter
            }
        }
    }

    @ViewBuilder
    private var remainingMeter: some View {
        if case .runningLow(let remaining) = reason,
           let allowance = (store.access.plan ?? .free).allowanceSeconds,
           allowance > 0 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(ColorPalette.caution)
                        .frame(width: geo.size.width * min(1, max(0, remaining / allowance)))
                }
            }
            .frame(height: 6)
            .padding(.top, 4)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    var plans: some View {
        if store.products.isEmpty {
            if store.productsUnavailable {
                unavailableNotice
            } else {
                loadingPlaceholder
            }
        } else {
            VStack(spacing: 10) {
                periodPicker

                ForEach(StoreManager.Tier.allCases) { tier in
                    PlanCard(
                        tier: tier,
                        price: store.priceLabel(for: tier, period: period),
                        note: period == .yearly
                            ? store.effectiveMonthlyPrice(for: tier).map { String(localized: "\($0) a month") }
                            : nil,
                        selected: chosen == tier,
                        select: { chosen = tier }
                    )
                }
            }
            .animation(Motion.tap, value: chosen)
        }
    }

    private var periodPicker: some View {
        BillingPeriodPicker(period: $period, saving: store.smallestYearlySaving)
    }

    @ViewBuilder
    var buyButton: some View {
        if let product = store.product(for: chosen, period: period),
           let price = store.compactPriceLabel(for: chosen, period: period) {
            VStack(alignment: .leading, spacing: 10) {
                WelcomePrimaryButton(
                    title: store.isPurchasing
                        ? String(localized: "Contacting the App Store…")
                        : String(localized: "Continue with \(chosen.name) · \(price)")
                ) {
                    Task {
                        // Captured before the await, because `chosen` is a live selection: somebody
                        // tapping another card while the store is answering should not change what
                        // the confirmation goes on to say they bought.
                        let buying = chosen
                        switch await store.purchase(product) {
                        case .purchased:
                            justBought = buying
                        case .pending:
                            awaitingApproval = true
                        case .cancelled:
                            break
                        case .failed:
                            break
                        }
                    }
                }
                .disabled(store.isPurchasing)

                if awaitingApproval {
                    Text("Waiting for approval. This plan starts as soon as whoever has to approve it does, and nothing is charged until then.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            }
        }
    }

    private var loadingPlaceholder: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, 32)
    }

    private var unavailableNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prices could not be loaded")
                .font(.subheadline.weight(.semibold))

            Text("The App Store returned no products for this app. If you have subscribed before, restoring should bring it back. Otherwise it is usually temporary.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await store.start() }
            } label: {
                Text("Try again").font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    var footer: some View {
        VStack(spacing: 18) {
            VStack(spacing: 12) {
                Text("On your own network Peering is free. A plan pays for the relay, the server that carries your session when your Mac is somewhere else, and adds the tools for working away from it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showsEverythingIncluded = true
                } label: {
                    HStack(spacing: 6) {
                        Text("See everything Peering does")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(ColorPalette.ink)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)

                Button {
                    Task {
                        if await store.restore() {
                            restoreNote = nil
                            justBought = store.activeTier
                        } else if store.purchaseError == nil {
                            restoreNote = String(localized: "No purchases to restore on this Apple Account.")
                        }
                    }
                } label: {
                    Text("Restore purchases")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }

            if let note = restoreNote ?? store.purchaseError {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(store.purchaseError == nil ? .secondary : ColorPalette.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 9) {
                Text("\(period == .monthly ? String(localized: "This subscription renews every month") : String(localized: "This subscription renews every year")) until cancelled, whichever plan you choose. You can cancel any time in your App Store settings. Payment is taken from your Apple Account when you confirm.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
    }

    /// The two links a screen selling an auto-renewable subscription is required to carry, and the
    /// reason there is a site at all: the pages are served by the relay, out of `Relay/site`, and
    /// both are plain HTML with no script for the reviewer whose browser runs none.
    var legalLinks: some View {
        HStack(spacing: 18) {
            Link("Privacy Policy", destination: Legal.privacy)
            Link("Terms of Use", destination: Legal.terms)
        }
        .font(.caption2)
        // Brightness rather than the accent, which in this app means "this one is on" and nothing
        // else. A link is a thing to press, not a thing that is selected, and the system's own
        // answer for the difference is how bright it is. `.secondary` and not `.tertiary`, which is
        // what made them invisible where they used to be.
        .foregroundStyle(.secondary)
    }
}
