import MacCastKit
import StoreKit
import SwiftUI

struct PaywallView: View {

    @Environment(StoreManager.self) var store
    var reason: Reason = .upgrade
    var onDismiss: () -> Void

    @State var chosen: StoreManager.Tier = .pro

    @State var period: BillingPeriod = .monthly
    @State var showsEverythingIncluded = false

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

            // It used to be `containerRelativeFrame(.vertical, alignment: .center)`, which centres
            // unconditionally — and a centred thing that is taller than its screen is cut off at
            // *both* ends, with the scroll starting somewhere in the middle. That was survivable
            // with two products and is not with three: the first thing on the screen was the top
            // half of a glyph under the status bar, and the sentence explaining what the money is
            // for was above the fold, where nobody looks for it.
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        plans
                        footer
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 24)
                    .frame(minHeight: geometry.size.height, alignment: .center)
                }
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
            }

            // A sheet has no status bar of its own, so `SkipButton`'s own 6 points put the word
            // against the top of a rounded corner, nearer the edge than anything else on the
            // screen — the content below it starts 24 points in. The rest of the way there is
            // added here rather than in `SkipButton`, which the welcome flow uses inside the safe
            // area, where the same 6 points already sit well below the status bar.
            SkipButton(action: onDismiss)
                .padding(.top, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            if let tier = justBought {
                ThankYouView(tier: tier, onDismiss: onDismiss)
                    .transition(.opacity)
            }
        }
        .animation(Motion.settle, value: justBought != nil)
        .task { await store.start() }
        .sheet(isPresented: $showsEverythingIncluded) {
            PlanFeaturesView()
        }
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
    }


}

// MARK: - The session the relay ended
