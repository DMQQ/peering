import StoreKit
import SwiftUI

/// What there is to buy, and what it costs.
///
/// Reachable from three places now, and it used to be reachable from one: the relay refusing a
/// connection for quota. Nothing else in the app could open it, which meant that a user who wanted
/// to subscribe — rather than one who had just been turned away — had nowhere to go. A purchase
/// screen that only exists behind an error is a purchase screen most people never see.
///
/// Three tiers rather than a list of products, and the difference is the comparison. A list of
/// products is a price each and nothing to choose between; a ladder of tiers is what the money
/// buys, one above the other, so the question the screen asks is "which of these is worth it"
/// rather than "how much is this one". The order is the argument, which is why the cards are in
/// `Tier.allCases` order and never in the order the store answered in.
struct PaywallView: View {
    /// Which door the user came through, because the sentence at the top is not the same.
    ///
    /// The copy was written for the quota case: "your free relay time for this month is used up".
    /// Through a door of the user's own choosing that sentence is simply false, and a false
    /// sentence at the top of a purchase screen is the sort of thing that costs the sale and earns
    /// the review. Same products either way; only the reason changes.
    ///
    /// It changes twice over, in fact, because there are two ways to hit the quota now: a free user
    /// who has spent half an hour, and a Relay subscriber who has spent their three hours. Telling
    /// the second one that their *free* allowance is gone reads as the app having forgotten they
    /// paid, which is worse than saying nothing.
    /// Five doors now, and the two newest are the ones the app opens by itself. The other three are
    /// somewhere the user went; these two are the app deciding that a moment has arrived — the first
    /// session anyone has ever finished, and an allowance that is nearly spent. Which is why the
    /// condition for ending each of them is written down in ``SessionModel/offerSubscriptionIfDue(after:)``
    /// rather than here: a screen that could decide to show itself would be a screen that shows
    /// itself.
    enum Reason {
        case quotaExhausted
        case upgrade
        /// The first session this device ever finished. Offered once, ever.
        case firstSession
        /// A relay session that ended with the day's allowance still there but nearly gone.
        ///
        /// Carries the figure, because the figure is most of the sentence: "running low" with no
        /// number is a nag, and a number is a fact the user can decide about. It is a snapshot taken
        /// when the session ended rather than a live reading — nothing can spend the allowance while
        /// the sheet is up, and a figure that moved would be a second source for a number the
        /// sentence above it has already committed to.
        case runningLow(remaining: TimeInterval)

        var title: String {
            switch self {
            case .quotaExhausted: return "Keep going from anywhere"
            case .upgrade: return "Connect from anywhere"
            case .firstSession: return "Take it with you"
            case .runningLow: return "Running low on relay time"
            }
        }

        /// The sentence under the title. `plan` is the plan the user is on, so that the wall they
        /// hit is described in terms of what they actually had.
        func detail(for plan: RelayPlan) -> String {
            switch self {
            case .quotaExhausted:
                switch plan {
                case .free:
                    return "Your free relay time for today is used up. Upgrade to connect from anywhere without limits."
                case .relay:
                    return "Your \(plan.allowanceSpelling) of relay for today are used up. Relay Plus and Pro remove the daily limit."
                case .plus, .pro:
                    // Unreachable as the app is wired: an unlimited plan is never metered, so the
                    // relay cannot refuse one for quota. Saying what a plan with no allowance is
                    // out of would be nonsense, so this says the true thing instead.
                    return "The relay is counting this connection against a quota your plan does not have. Try again, and get in touch if it keeps happening."
                }
            case .upgrade:
                // The ladder in one sentence, with the two numbers read off the same place the
                // meter reads them from. The cards below say the rest.
                return "The relay reaches your Mac when it is on another network. Peering includes \(RelayPlan.free.allowanceSpelling) of relay every day; Relay raises that to \(RelayPlan.relay.allowanceSpelling), and the plans above it remove the limit."
            case .firstSession:
                // Opened by the app, so it opens by naming the moment. Without that first clause
                // this is a purchase screen that has appeared out of nowhere a second after the
                // session ended, which reads as the app having pounced rather than followed up.
                let moment = "That was your first session. Relay is the part of Peering that reaches your Mac when this iPhone is not on the same network."
                switch plan {
                case .free:
                    return "\(moment) \(RelayPlan.free.allowanceSpelling.capitalized) a day comes with the app; Relay raises that to \(RelayPlan.relay.allowanceSpelling), and the plans above it remove the limit."
                case .relay:
                    // Somebody who subscribed on the last page of the introduction, before they had
                    // ever connected. Selling them the relay again would be the app having forgotten
                    // they paid, so this says what they already have.
                    return "\(moment) You are already subscribed, so today's \(plan.allowanceSpelling) of it is what carried this one."
                case .plus, .pro:
                    // Unreachable for the same reason as the case below it, and said truly rather
                    // than left blank.
                    return "\(moment) Your plan already includes unlimited relay, so there is nothing here to buy."
                }
            case .runningLow(let remaining):
                // Plan-aware for the reason the exhausted case is: telling a Relay subscriber that
                // Relay raises the allowance to the allowance they already have is the app reading
                // its own copy back without having checked who is looking at it.
                let left = RelayTime.label(remaining)
                switch plan {
                case .free:
                    return "\(left) left of today's free relay time. When it runs out the relay stops working until tomorrow. Relay raises that to \(RelayPlan.relay.allowanceSpelling) a day, and the plans above it remove the limit."
                case .relay:
                    return "\(left) left of today's relay time. When it runs out the relay stops working until tomorrow. The plans above remove the daily limit."
                case .plus, .pro:
                    // Unreachable as the app is wired: an unmetered plan has no remaining figure to
                    // be low, so ``SessionModel/relaySecondsRemainingEstimate`` is `nil` for one and
                    // nothing can construct this reason. True rather than blank.
                    return "\(left) left of today's relay time."
                }
            }
        }
    }

    @Environment(StoreManager.self) private var store
    var reason: Reason = .upgrade
    var onDismiss: () -> Void

    /// Which card the buy button is pointed at.
    ///
    /// It opens on the recommended tier rather than on nothing, because the recommendation is what
    /// the badge and the ladder are for — a screen that has an opinion and then makes the user pick
    /// before it will say it is a screen that has not decided either.
    @State private var chosen: StoreManager.Tier = .pro
    /// Whether the full feature list is up. A sheet rather than a push: this view is already
    /// presented as one, and a navigation stack here would give the paywall a back button it has
    /// never had.
    @State private var showsEverythingIncluded = false

    var body: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()
            light

            // Centred while it fits and scrolled from the top when it does not.
            //
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
                        buyButton
                        footer
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 24)
                    .frame(minHeight: geometry.size.height, alignment: .center)
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
        }
        .task { await store.start() }
        .sheet(isPresented: $showsEverythingIncluded) {
            PlanFeaturesView()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "network")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(ColorPalette.ink)
                .frame(height: 56)

            VStack(alignment: .leading, spacing: 8) {
                // The display face, at the size ``TabScreenHeader`` uses scaled down to this
                // header's rung — 34 points is a screen title and this is one step under the
                // icon and above the detail. The tracking is the same proportion as that
                // header's: a serif set at this size closes up without it, and the screen
                // selling the app was the one place it was not set at all.
                Text(reason.title)
                    .font(DisplayFont.display(28))
                    .tracking(-1)

                Text(reason.detail(for: store.relayPlan))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                remainingMeter
            }
        }
    }

    /// The bar the "running low" door draws, and only that door.
    ///
    /// The figure is already in the sentence above it, so this is not how the number is read. It is
    /// what makes the sentence land: a bar three-quarters empty says "nearly gone" in the time a
    /// glance takes, where the words take a line to say it — and this screen is asking for money on
    /// the strength of how little is left.
    ///
    /// The same arithmetic as the meter in the Sessions tab, over the same 24-hour window, but not
    /// the same view: that one is a live reading against a model and this is a fixed proportion of a
    /// figure the reason is carrying. It is one number drawn twice, not two numbers.
    @ViewBuilder
    private var remainingMeter: some View {
        if case .runningLow(let remaining) = reason,
           let allowance = store.relayPlan.allowanceSeconds,
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
            // The sentence above it is the accessible version of this, and a bar has no reading
            // that would not simply repeat it with the same number.
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var plans: some View {
        if store.products.isEmpty {
            if store.productsUnavailable {
                unavailableNotice
            } else {
                loadingPlaceholder
            }
        } else {
            VStack(spacing: 10) {
                ForEach(StoreManager.Tier.allCases) { tier in
                    PlanCard(
                        tier: tier,
                        price: store.priceLabel(for: tier),
                        selected: chosen == tier,
                        select: { chosen = tier }
                    )
                }
            }
            // The whole ladder moves by one animation rather than each card appearing on its own:
            // the three are one object — a comparison — and a comparison that assembles itself a
            // third at a time reads as three separate offers that happen to be stacked.
            .animation(Motion.tap, value: chosen)
        }
    }

    /// The one button that buys, pointed at whichever card is selected.
    ///
    /// One button under three cards rather than one per card. Three buy buttons is three chances to
    /// tap the wrong one, and the price belongs on the button rather than only on the card: the card
    /// says what the tier is, and the button is the moment the money is decided, so it is the last
    /// place the number can be read before it is spent.
    @ViewBuilder
    private var buyButton: some View {
        if let product = store.product(for: chosen),
           let price = store.compactPriceLabel(for: chosen) {
            VStack(alignment: .leading, spacing: 10) {
                WelcomePrimaryButton(
                    title: store.isPurchasing
                        ? "Contacting the App Store…"
                        : "Continue with \(chosen.name) · \(price)"
                ) {
                    Task { await store.purchase(product) }
                }
                .disabled(store.isPurchasing)

                if let error = store.purchaseError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(ColorPalette.danger)
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

    /// What is shown when the App Store answers with nothing at all.
    ///
    /// This used to be the spinner, forever: an empty product list meant "still loading" and there
    /// was no second state to distinguish it from "the store has no such products", which is what
    /// happens on every launch until the products exist in App Store Connect. A spinner that never
    /// stops is worse than an error — it looks like the app is thinking, so the user waits.
    private var unavailableNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prices could not be loaded")
                .font(.subheadline.weight(.semibold))

            Text("The App Store returned no products for this app. If you have subscribed before, restoring should bring it back. Otherwise this is usually temporary.")
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

    private var footer: some View {
        VStack(spacing: 10) {
            // The whole inventory, one tap away.
            //
            // A paywall is a comparison, and a comparison is only as honest as what it leaves out:
            // three cards can each carry a handful of lines, and the screen's job is to be
            // decidable, not to be complete. This is where complete lives — so the case for the
            // subscription is not made by omission.
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
                Task { await store.restore() }
            } label: {
                Text("Restore purchases")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            // The two links a screen selling an auto-renewable subscription is required to carry,
            // and the reason there is a site at all: the pages are served by the relay, out of
            // `Relay/site`, and both are plain HTML with no script for the reviewer whose browser
            // runs none.
            HStack(spacing: 18) {
                Link("Privacy Policy", destination: Legal.privacy)
                Link("Terms of Use", destination: Legal.terms)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            // The renewal terms, in the smallest type on the screen and the only place they are
            // said. A subscription screen is required to state that it renews and how to stop it,
            // and beyond the requirement it is the one sentence here that answers the question
            // somebody about to pay is actually asking.
            //
            // Both periods are named because the ladder now has both: a sentence that said "every
            // month" would be a false statement about the tier the screen is recommending.
            Text("Subscriptions renew automatically until cancelled, the monthly plans every month and Pro every year. You can cancel any time in your App Store settings. Payment is taken from your Apple Account when you confirm.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Relay carries your encrypted session. It cannot read what it forwards.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private var light: some View {
        RadialGradient(
            colors: [.white.opacity(0.07), .clear],
            center: .top,
            startRadius: 0,
            endRadius: 460
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Legal

/// Where the two documents live.
///
/// Named here rather than typed into the two `Link`s because the App Store listing carries the same
/// two URLs, and a pair of addresses that has to agree with a web form nobody can compile is a pair
/// worth keeping in one place. The pages are served by the relay itself — see `Relay/site`.
enum Legal {
    static let privacy = URL(string: "https://getpeering.app/privacy")!
    static let terms = URL(string: "https://getpeering.app/terms")!
}

// MARK: - Plan card

/// One rung of the ladder: what it is called, what it costs, and what is in it.
///
/// The three are deliberately the same shape, down to the count of lines where it can be managed,
/// because a comparison is only a comparison if the parts line up. The one that differs is the
/// badge — and the price, and the length of the list, which is the whole point of putting them
/// side by side.
private struct PlanCard: View {
    let tier: StoreManager.Tier
    let price: String?
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(tier.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(ColorPalette.ink)

                    if tier.isRecommended {
                        Text("BEST VALUE")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.7)
                            .foregroundStyle(ColorPalette.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(ColorPalette.accent.opacity(0.18), in: Capsule())
                    }

                    Spacer(minLength: 8)

                    // Three dots rather than a dash for a price the store has not answered with.
                    // A dash in a price column reads as a minus sign, and this is the one place on
                    // the screen where a mark that could be arithmetic is worth avoiding.
                    Text(price ?? "···")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ColorPalette.ink)
                        .multilineTextAlignment(.trailing)
                }

                Text(tier.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 5) {
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
            .cardSurface()
            .overlay {
                // The ring is always there and only its opacity moves, so the card does not change
                // size when it is picked — a selected card that grows moves the one below it, which
                // is the card the user is looking at when they tap.
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

#Preview {
    PaywallView(onDismiss: {})
        .environment(StoreManager())
        .preferredColorScheme(.dark)
}
