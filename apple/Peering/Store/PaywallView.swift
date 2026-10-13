import PeeringKit
import StoreKit
import SwiftUI

struct PaywallView: View {

    @Environment(StoreManager.self) var store
    var reason: Reason = .upgrade
    var onDismiss: () -> Void

    @State var chosen: PlanOffer? = .subscription

    /// Deliberately not `store.activeTier`, which is also non-nil for somebody who subscribed last
    /// month and opened this sheet through the upgrade door: a confirmation shown to them is a
    /// screen that has stopped offering anything. Only a purchase that happened here, or a plan
    /// that became active while this sheet was open, sets this.
    @State var justBought: StoreManager.Tier?

    @State var awaitingApproval = false

    @State var restoreNote: String?

    var body: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()
            TopGlow()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    plans
                    footer
                }
                .padding(.horizontal, 18)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }
            // The sheet is dismissed by swiping it down, so a page that fits does not bounce.
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if justBought == nil {
                        buyButton
                    }

                    legalLinks
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(.ultraThinMaterial)
            }

            if let tier = justBought {
                ThankYouView(tier: tier, onDismiss: onDismiss)
                    .transition(.opacity)
            }
        }
        .animation(Motion.settle, value: justBought != nil)
        .task { await store.start() }
        // A purchase sent for approval comes back through `Transaction.updates` rather than
        // through the call that started it, so this is where it lands. It is also where a
        // renewal lands, and where a restore that found something lands: all three mean the same
        // thing on this screen, which is that there is nothing left here to sell.
        .onChange(of: store.activeTier) { _, tier in
            guard let tier else { return }
            awaitingApproval = false
            justBought = tier
        }
        .onAppear { Analytics.paywallShown(reason: reason.analyticsName) }
        .onDisappear { if justBought == nil { Analytics.paywallDismissed(reason: reason.analyticsName) } }
    }
}

// MARK: - The session the relay ended
