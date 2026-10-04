import MacCastKit
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
extension View {
    /// Presents the purchase sheet for whatever reason the model is currently carrying.
    ///
    /// **Attached in more than one place, and it has to be, which is the whole reason this is a
    /// modifier rather than a `.sheet` written out where it is needed.** A sheet can only be
    /// presented by a view that is not already presenting one. This app puts locks inside sheets:
    /// the terminal is a sheet, and its deck, its quick commands and the file browser all carry one.
    /// A paywall presented from the root while the terminal is up is a presentation UIKit refuses
    /// in silence, and the failure looks exactly like the app ignoring the tap.
    ///
    /// So every sheet that can hold a lock attaches this as well, and the copy nearest the top of
    /// the stack is the one that gets to present. Two bindings over one `paywallReason` is not the
    /// race it looks like: both read the same value, both set it to `nil` on the way down, and only
    /// one of them is ever in a position to open.
    func presentsPaywall(_ model: SessionModel) -> some View {
        sheet(isPresented: Binding(
            get: { model.paywallReason != nil },
            set: { if !$0 { model.paywallReason = nil } }
        )) {
            PaywallView(reason: model.paywallReason ?? .upgrade) { model.paywallReason = nil }
                .environment(model.storeManager)
                .preferredColorScheme(.dark)
        }
    }
}

struct PaywallView: View {
    /// Which door the user came through, because the sentence at the top is not the same.
    ///
    /// The copy was written for the quota case: "your free relay time for this month is used up".
    /// Through a door of the user's own choosing that sentence is simply false, and a false
    /// sentence at the top of a purchase screen is the sort of thing that costs the sale and earns
    /// the review. Same products either way; only the reason changes.
    ///
    /// It changes twice over, in fact, because there are two ways to hit the quota now: a free user
    /// who has spent the free allowance, or an impossible paid-plan quota response. Telling a
    /// subscriber that their *free* allowance is gone reads as the app having forgotten they paid,
    /// which is worse than saying nothing.
    /// Six doors now, and the two the app opens by itself are the ones that are not the user's
    /// doing. Of the other four, three are somewhere the user went; the newest is a control they
    /// pressed that did nothing, which is the one door opened by somebody who was not asking to buy
    /// anything. Which is why the condition for ending each of the two automatic ones is written
    /// down in ``SessionModel/offerSubscriptionIfDue(after:)`` rather than here: a screen that could
    /// decide to show itself would be a screen that shows itself.
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
        /// A feature the user just reached for, on a plan that does not include it.
        ///
        /// **The one door opened by a control that did nothing.** Every other reason here is either
        /// a wall the relay put up or something the app decided to say; this one is a badge on the
        /// thing under the user's thumb, and the sheet has to open by naming it. Without that, the
        /// answer to a tap that did nothing is a purchase screen out of nowhere, which reads as the
        /// app having ignored the tap and then tried to sell something.
        ///
        /// It carries the capability rather than a string, because the feature's name, the plan
        /// that unlocks it and the badge on the row that sells it are one fact, and this file is
        /// not allowed to become the second copy of it. See ``PlanCapability``.
        case feature(PlanCapability)

        var title: String {
            switch self {
            case .quotaExhausted: return String(localized: "Keep going from anywhere")
            case .upgrade: return String(localized: "Connect from anywhere")
            case .firstSession: return String(localized: "Take it with you")
            case .runningLow: return String(localized: "Running low on relay time")
            // Names the thing that was pressed, because that is the whole difference between this
            // door and the others: the user did not tap a button marked Subscribe, they tapped the
            // feature. "Unlock" rather than "X is part of Relay", which reads as a plural subject
            // with a singular verb on the one capability that is three features in a row.
            case .feature(let capability): return String(localized: "Unlock \(capability.name)")
            }
        }

        /// The sentence under the title. `plan` is the plan the user is on, so that the wall they
        /// hit is described in terms of what they actually had.
        func detail(for plan: RelayPlan) -> String {
            switch self {
            case .feature(let capability):
                // The plan that unlocks it is named rather than the plan the user is on, because
                // that is the question the tap asked. Their own plan appears only to say what it
                // does not do, and it appears as "the free plan" rather than as "Free": the one
                // name is a label on a card and the other is a phrase in a sentence, and a
                // purchase screen that says "It is not in Free" reads as a translation.
                let unlocking = capability.minimumPlan
                guard plan < unlocking else {
                    // Unreachable as the app is wired: a gate asks ``PlanAccess``, and a plan that
                    // includes a capability never draws the lock that opens this door. True rather
                    // than blank, like the two other unreachable branches below.
                    return String(localized: "\(Self.whatItIs(capability)) Your plan already includes it.")
                }
                let current = plan == .free ? String(localized: "the free plan") : plan.name
                return String(localized: "\(Self.whatItIs(capability)) It is not in \(current). \(unlocking.name) adds it.")
            case .quotaExhausted:
                switch plan {
                case .free:
                    return String(localized: "Your free relay time for today is used up. Upgrade to connect from anywhere without limits.")
                case .relay, .plus, .pro:
                    // Unreachable as the app is wired: paid plans are unlimited and never metered,
                    // so the relay cannot refuse one for quota. True rather than blank.
                    return String(localized: "The relay counted this connection against a quota your plan does not have. Try again, and tell us if it keeps happening.")
                }
            case .upgrade:
                // The ladder in one sentence, with the two numbers read off the same place the
                // meter reads them from. The cards below say the rest.
                // The two rungs are named rather than pointed at. "The plans above it" reads as a
                // direction, and the cards it means are *below* this sentence on the screen.
                return String(localized: "Reaching a Mac on another network runs on the relay, which is metered. Free includes \(RelayPlan.free.allowanceSpelling) a day. Any paid plan removes the limit.")
            case .firstSession:
                // Opened by the app, so it opens by naming the moment. Without that first clause
                // this is a purchase screen that has appeared out of nowhere a second after the
                // session ended, which reads as the app having pounced rather than followed up.
                let moment = String(localized: "That was your first session. Relay is the part of Peering that reaches your Mac when this device is not on the same network.")
                switch plan {
                case .free:
                    return String(localized: "\(moment) Free includes \(RelayPlan.free.allowanceSpelling) of relay a day. Any paid plan removes the limit.")
                case .relay:
                    // Somebody who subscribed on the last page of the introduction, before they had
                    // ever connected. Selling them the relay again would be the app having forgotten
                    // they paid, so this says what they already have.
                    return String(localized: "\(moment) You are already subscribed, so there was no meter on this one.")
                case .plus, .pro:
                    // Unreachable for the same reason as the case below it, and said truly rather
                    // than left blank.
                    return String(localized: "\(moment) Your plan already includes unlimited relay, so there is nothing here to buy.")
                }
            case .runningLow(let remaining):
                let left = RelayTime.label(remaining)
                switch plan {
                case .free:
                    return String(localized: "\(left) left today. When it runs out, reaching a Mac on another network stops until the allowance comes back. Any paid plan removes the limit.")
                case .relay, .plus, .pro:
                    // Unreachable as the app is wired: paid plans are unlimited, so
                    // ``SessionModel/relaySecondsRemainingEstimate`` is `nil` for them and nothing
                    // can construct this reason. True rather than blank.
                    return String(localized: "\(left) left of today's relay time.")
                }
            }
        }

        /// What one gated feature is, in a sentence, for the door opened by a locked control.
        ///
        /// **Here and not on ``PlanCapability``**, which carries the name and the plan and nothing
        /// else. What a feature *is* is a sentence written for a reader, and the map is a fact
        /// about the product: a package that shipped the sales copy would be a package that has to
        /// be edited to reword it, and the test that guards the map would be guarding prose. The
        /// two are kept together by the capability being one value, so the sentence here and the
        /// badge on the row that sells it cannot come apart.
        ///
        /// Every one of these follows the line the "Everything included" list uses, because the two
        /// are read by the same person minutes apart and a feature described one way on the card
        /// and another way on the sheet is the drift the map exists to stop.
        private static func whatItIs(_ capability: PlanCapability) -> String {
            switch capability {
            case .extraMacs:
                return String(localized: "Free pairs with one Mac. This is every Mac after it.")
            case .concurrentSessions:
                return String(localized: "One Mac at a time is free. This keeps them all open, so switching is a tap rather than a reconnection.")
            case .macSound:
                return String(localized: "Whatever the Mac is playing comes out of this device, from the music you left running to the alert it makes in answer to a key you sent it.")
            case .pictureInPicture:
                return String(localized: "The Mac's screen floats over your other apps, and iOS floats it by itself when you leave.")
            case .clipboardHistory:
                return String(localized: "The last twelve things that crossed between the two, still there when you think of them. Copying and pasting are on every plan.")
            case .mosaic:
                // The Mac's own cost is named, because it is the honest reason this is on the
                // top rung and it is a thing the reader can feel: six windows in one picture is
                // six captures happening at once on the machine they are asking.
                return String(localized: "Pick several of the Mac's windows and see them together, arranged the way you want on this screen. Every tile is captured separately on the Mac, so the picture stays live rather than being a screenshot, and tapping one takes you into it.")
            case .virtualDisplays:
                return String(localized: "A screen the Mac does not physically have, made from this phone and looked at from it: somewhere else for its windows to go, named and taken away from the same list.")
            case .terminalAlerts:
                return String(localized: "A banner when a shell on the Mac or on one of your servers stops and waits for you, on this device while it is open and through the Mac when it is not. The terminal and its own attention mark are on every plan.")
            case .fileTransfer:
                return String(localized: "Takes what you are looking at off a machine and hands it to Files or the share sheet, and puts a file from the phone into the folder you are looking at, up to 2 GB.")
            case .shellTabs:
                return String(localized: "One shell at a time is free, on your Mac and on any server. This is naming tabs and keeping several open.")
            case .macros:
                return String(localized: "Save a sequence and fire it with a tap. The commands you type most wait as chips above the terminal keyboard, in every shell.")
            case .highBitrate:
                // The direct path is named, because it is the half of the answer nobody expects
                // and the half that keeps this from reading as a cap on the app. It also happens
                // to be true: a session going straight between the two devices is not capped on
                // any plan, so what is being sold is the picture on the way round.
                return String(localized: "A sharper picture when the session is relayed. On your own network it is already uncapped on every plan.")
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

    /// How often the user wants to be billed.
    ///
    /// Opens on the monthly. It used to open on the yearly, on the argument that the yearly is the
    /// better value and the monthly exists to make it look like one. That is true of the money and
    /// it was wrong about the screen: the first price a person reads on a page asking for money
    /// should be the smallest one it can honestly ask for, and a switch that opens on the larger
    /// number turns the smaller one into a retreat from the offer rather than an offer of its own.
    /// The yearly is one tap away and keeps the saving badge, which is the argument for it; it does
    /// not also need to be the default.
    ///
    /// Still a choice rather than a default the screen hides: the switch says what it is doing, and
    /// every price below it moves when it moves.
    @State private var period: BillingPeriod = .monthly
    /// Whether the full feature list is up. A sheet rather than a push: this view is already
    /// presented as one, and a navigation stack here would give the paywall a back button it has
    /// never had.
    @State private var showsEverythingIncluded = false

    /// The tier this sheet watched somebody buy, so it can say so instead of going on selling.
    ///
    /// Deliberately not `store.activeTier`, which is also non-nil for somebody who subscribed last
    /// month and opened this sheet through the upgrade door: a confirmation shown to them is a
    /// screen that has stopped offering anything. Only a purchase that happened here, or a plan
    /// that became active while this sheet was open, sets this.
    @State private var justBought: StoreManager.Tier?

    /// Between sending a purchase for approval and the App Store answering.
    ///
    /// Its own state rather than an error, because it is not one: Ask to Buy and a bank check are
    /// both "not yet", and the screen used to say nothing at all for them, which from the user's
    /// side is indistinguishable from the app having dropped the purchase on the floor.
    @State private var awaitingApproval = false

    /// What a restore came to, when it came to nothing.
    ///
    /// The one case the App Store answers with neither a plan nor an error, and the one a person
    /// taps Restore to find out about. Cleared by the next restore that works.
    @State private var restoreNote: String?

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
                        footer
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 24)
                    .frame(minHeight: geometry.size.height, alignment: .center)
                }
                // **The button that pays does not scroll away.** Three cards with their feature
                // lists are taller than a phone, so the price and the way to accept it used to sit
                // below the fold: the screen asked for money and then made the reader go and find
                // the button. Pinned to the bottom instead, over the cards, which is also the one
                // place the price can be read at the moment the things it is being weighed against
                // are on screen. The material is what stops the text underneath reading as part of
                // it.
                //
                // The two links ride in this bar as well, and for the same reason the button does:
                // see ``legalLinks``. The shop is the one corner of this screen that is on screen
                // whatever the cards are doing, so it is where a thing that must be seen goes.
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
                periodPicker

                ForEach(StoreManager.Tier.allCases) { tier in
                    PlanCard(
                        tier: tier,
                        price: store.priceLabel(for: tier, period: period),
                        // Only on the yearly, and only under the yearly price: it is the same money
                        // already divided by twelve, so it belongs directly beneath the sum it
                        // explains. Beside the monthly price it would be the yearly arguing for
                        // itself, which is the switch's job rather than the card's.
                        note: period == .yearly
                            ? store.effectiveMonthlyPrice(for: tier).map { String(localized: "\($0) a month") }
                            : nil,
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

    /// The monthly/yearly switch, and the reason the three cards above it can be compared at all.
    ///
    /// Above the cards rather than under them, because it changes what every price below it means.
    /// A switch that moves the numbers it sits beneath is a switch whose effect is discovered
    /// rather than seen, and on a screen whose whole job is a comparison that is the wrong way
    /// round.
    ///
    /// The yearly carries the saving and the monthly carries nothing, because being the smaller
    /// commitment is the monthly's own argument. The number is the smallest saving across the three
    /// plans rather than any one plan's, since it is printed once and applies to all of them: the
    /// three land within a couple of points of each other, and the smallest is the one that is true
    /// whichever card is selected.
    private var periodPicker: some View {
        BillingPeriodPicker(period: $period, saving: store.smallestYearlySaving)
    }

    /// The one button that buys, pointed at whichever card is selected.
    ///
    /// One button under three cards rather than one per card. Three buy buttons is three chances to
    /// tap the wrong one, and the price belongs on the button rather than only on the card: the card
    /// says what the tier is, and the button is the moment the money is decided, so it is the last
    /// place the number can be read before it is spent.
    @ViewBuilder
    private var buyButton: some View {
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
                            // `purchaseError` is set for both the refusal and the unverifiable
                            // case, and it is rendered directly below.
                            break
                        }
                    }
                }
                .disabled(store.isPurchasing)

                // Not an error, so not in the error's colour: nothing has gone wrong, and the
                // only thing the user needs to know is that waiting is the right thing to do.
                if awaitingApproval {
                    Text("Waiting for approval. This plan starts as soon as whoever has to approve it does, and nothing is charged until then.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The error is not rendered here. It moved to the footer, because the state that
                // most needs to show one is the state with no products loaded, and that is the
                // state where this whole view does not exist. See `footer`.
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

    /// Everything under the cards: the two ways out that are not buying, and the renewal terms.
    ///
    /// **Two blocks with a gap, rather than six centred lines at one spacing.** Everything here
    /// used to be ten points apart — two buttons, then two links, then three short paragraphs and a
    /// sentence — and equal spacing is what made it read as a wall: nothing in it said which line
    /// was something to press and which was something the App Store requires the screen to say.
    /// The actions are now one group, the legal text another, and the space between the groups is
    /// the largest gap below the cards, so the eye can tell where the offer ends.
    ///
    /// The two links that used to close this out are in the pinned bar now rather than down here,
    /// because down here they were reachable and unfindable. See ``legalLinks``.
    ///
    /// **It used to end on a third line, and that line is gone.** "Relay carries your encrypted
    /// session. It cannot read what it forwards." was true, and it was the only thing down here
    /// that the App Store does not require, which made it the only thing that could go. Three
    /// stacked blocks under the cards is a wall however well spaced they are, and the reassurance
    /// was the cheapest of the three: the privacy claim belongs on the page that is about privacy,
    /// where it can be made properly, rather than tacked under a price.
    private var footer: some View {
        VStack(spacing: 18) {
            VStack(spacing: 12) {
                // What the money is for. Next to one-off purchases, a subscription reads as a
                // choice unless it says what keeps costing.
                Text("On your own network Peering is free. A plan pays for the relay, the server that carries your session when your Mac is somewhere else, and adds the tools for working away from it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                // The whole inventory, one tap away.
                //
                // A paywall is a comparison, and a comparison is only as honest as what it leaves
                // out: three cards can each carry a handful of lines, and the screen's job is to be
                // decidable, not to be complete. This is where complete lives, so the case for the
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
                    Task {
                        if await store.restore() {
                            restoreNote = nil
                            justBought = store.activeTier
                        } else if store.purchaseError == nil {
                            // Nothing found and nothing thrown, which used to be silence: the
                            // button was tapped, something may or may not have happened, and the
                            // screen said nothing either way.
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

            // **Where the error lives now.** It used to be rendered under the buy button, which
            // only exists once products have loaded, so in the "Prices could not be loaded"
            // state, whose own copy tells people to restore, a restore that failed had nowhere
            // to say so. This is below both buttons and always present.
            if let note = restoreNote ?? store.purchaseError {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(store.purchaseError == nil ? .secondary : ColorPalette.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 9) {
                // The renewal terms, in the smallest type on the screen and the only place they are
                // said. A subscription screen is required to state that it renews and how to stop
                // it, and beyond the requirement it is the one sentence here that answers the
                // question somebody about to pay is actually asking.
                //
                // Every period is named because every tier is now sold at both, and the sentence
                // has to be true whichever card and whichever switch position the user is looking
                // at. "The plan you chose" rather than a list, because the list is the switch's job
                // and a sentence that enumerated it would go stale the day a period is added.
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
    ///
    /// **They used to be the last thing in the scroll, under the last card, and they may as well
    /// not have been there.** They were correct in the sense that they existed and could be reached
    /// by scrolling far enough, and a requirement that nobody can find is not met. The buy button
    /// is pinned, so the screen looks finished the moment it opens: nothing invites a scroll past
    /// three cards with their feature lists to the smallest and faintest type on the page, and the
    /// one person guaranteed to look for those links is the reviewer, who has no reason to.
    ///
    /// In the pinned bar they are on screen the moment the sheet is, at every scroll position and
    /// in every state of the store, which is what being required actually asks for.
    private var legalLinks: some View {
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

// MARK: - The session the relay ended

/// What the app says when the relay ends a session because the day's allowance is spent.
///
/// **The one ending that has nothing on screen to explain it.** Every other way a session stops
/// says so somewhere: the Mac locked, the network went, the user tapped End. This one is a socket
/// closing. The relay ends a session the moment its window is spent, and it has nowhere to say
/// why: everything past the session token is a TLS connection it cannot write into, and the
/// signalling socket is a different connection that may already be closed. What the user sees is
/// their Mac vanishing, then a reconnect that is refused, and nothing anywhere about money.
///
/// **A sheet rather than an alert**, because there is something worth reaching on the other side of
/// it: the plans, one tap away, which is the only thing that can be done about the state the user
/// is in. An alert with the same two buttons would read as a failure report; this reads as an
/// explanation that ends in an offer, which is what it is.
///
/// **And it closes plainly.** Two buttons, either of which dismisses, plus the swipe every sheet
/// has. The session is over either way, so there is nothing an unclosable modal could protect,
/// and a screen with no way out is both the thing App Review rejects and a poor way to treat
/// somebody who has just lost their connection.
struct AllowanceSpentView: View {
    /// The plan that was running when the relay cut the session, taken then rather than read now.
    /// See ``SessionModel/spentAllowance``.
    let plan: RelayPlan
    let onDismiss: () -> Void

    @Environment(StoreManager.self) private var store

    /// The plans, opened over this sheet rather than in place of it.
    ///
    /// Presented from inside here rather than by closing this and setting the session's
    /// ``SessionModel/paywallReason``, which is how every other door opens it. Two sheets on one
    /// view cannot cross in the same update (the dismissal and the presentation race), and a
    /// nested sheet is the shape that does not. It also leaves the explanation where it was:
    /// skipping the prices comes back to the sentence saying what happened, rather than to the
    /// picker with nothing on it about the session that just ended.
    @State private var showsPlans = false

    var body: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()
            RadialGradient(
                colors: [.white.opacity(0.07), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 460
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(ColorPalette.ink)
                    .frame(height: 56)

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(DisplayFont.display(28))
                        .tracking(-1)

                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                WelcomePrimaryButton(title: String(localized: "See the plans")) { showsPlans = true }
                    .padding(.top, 4)

                Button("Not now") { onDismiss() }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showsPlans) {
            PaywallView(reason: .upgrade, onDismiss: { showsPlans = false })
                .environment(store)
                .preferredColorScheme(.dark)
        }
    }

    /// The headline, which names the allowance rather than the app's disappointment.
    ///
    /// "You have run out of relay time" is true of a figure the user has never seen. The allowance
    /// is a number the app has been drawing on the Sessions tab all along, and saying which one it
    /// was is the difference between a limit and a bug.
    private var title: String {
        switch plan {
        case .free: return String(localized: "Your free relay time is used up")
        case .relay, .plus, .pro:
            // Unreachable as the app is wired: paid plans are unlimited and never cut for quota.
            // True rather than blank, like the paywall's own unreachable branches.
            return String(localized: "The relay stopped the session")
        }
    }

    /// What happened, which allowance it was, and the one thing that is still free.
    ///
    /// The last sentence matters more than it looks. The reader's next move is to try again, or to
    /// conclude the app has stopped working; the thing that ends that is being told that the
    /// connection over their own network is unlimited and untouched by any of this, which it is on
    /// every plan including the free one.
    private var detail: String {
        let stillFree = String(localized: "Your own network is unlimited on every plan, and still works.")
        switch plan {
        case .free:
            return String(localized: "That session went over the relay, and free's \(plan.allowanceSpelling) a day are spent. Another relayed session is refused until the allowance comes back. \(stillFree)")
        case .relay, .plus, .pro:
            return String(localized: "Your plan has no daily limit, so the relay counting this one means it read the device as free. Try again, and tell us if it keeps happening. \(stillFree)")
        }
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
    /// A second line under the price, which the yearly uses to say what it works out at monthly.
    ///
    /// Under the price rather than beside the name, because it is not another fact about the plan:
    /// it is the same money as the line above it, divided differently, and the two have to be read
    /// together or the second one is just a smaller number in a second currency.
    let note: String?
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 10) {
                // **Above the name, which is where the site puts it and what it is worth.** Beside
                // the name the badge was a sibling of it competing for the same line, and on the
                // longest name on the ladder — Relay Plus — it took the width the name needed.
                // Above it, the recommendation is read before the thing it recommends, and the
                // three names line up down the page whatever each of them is called.
                if tier.isRecommended {
                    Text("Best value")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(ColorPalette.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(ColorPalette.accent.opacity(0.18), in: Capsule())
                }

                // The name and the price, stacked and in the display face, which is the site's
                // card in one column. The price used to be a `.subheadline` on the trailing edge
                // of the name's line, which made the two compete for the width and left the number
                // — the reason anybody is on this screen — the smallest thing in the header. Set
                // below the name at display size it is the anchor of the card, and the name above
                // it is what the anchor belongs to.
                VStack(alignment: .leading, spacing: 1) {
                    Text(tier.name)
                        .font(DisplayFont.display(21))
                        .tracking(-0.5)
                        .foregroundStyle(ColorPalette.ink)

                    // Three dots rather than a dash for a price the store has not answered with. A
                    // dash in a price column reads as a minus sign, and this is the one place on
                    // the screen where a mark that could be arithmetic is worth avoiding.
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

                // The tier's own tagline used to sit here, and it was the third place on the card
                // saying the same thing: "unlimited relay, on every Mac you own" is the
                // first two lines of the list below it, in fewer words and with a full stop. The
                // site's columns carry no such sentence either, and the sentence itself is still
                // what the confirmation screen says to somebody who has just bought.
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

// MARK: - Shared picker

/// The monthly / yearly toggle, shared by the paywall and the onboarding plans page.
///
/// Extracted because both screens need the same control and two hand-written copies of it are two
/// things to keep in step. The badge rides above the yearly half for the reason the paywall argues
/// at length: a badge that changes its neighbour's width makes the two halves of a switch two
/// different sizes. The `saving` parameter feeds the badge and the accessibility value; pass `nil`
/// when the store has not yet answered with both periods.
struct BillingPeriodPicker: View {
    @Binding var period: BillingPeriod
    /// Smallest saving across all yearly products, in whole percent. `nil` until the store answers.
    var saving: Int?

    private static let savingLift: CGFloat = 19

    var body: some View {
        HStack(spacing: 4) {
            ForEach(BillingPeriod.allCases) { option in
                Button {
                    period = option
                } label: {
                    Text(option == .monthly ? "Monthly" : "Yearly")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(period == option ? ColorPalette.ink : ColorPalette.ink.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            Capsule()
                                .fill(ColorPalette.accent.opacity(period == option ? 0.22 : 0))
                        }
                        .contentShape(Capsule())
                        .overlay(alignment: .top) {
                            if option == .yearly, let saving {
                                Text("Save \(saving)%")
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(0.4)
                                    .foregroundStyle(ColorPalette.accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(ColorPalette.accent.opacity(0.18), in: Capsule())
                                    .offset(y: -Self.savingLift)
                                    .accessibilityHidden(true)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(period == option ? [.isSelected] : [])
                .accessibilityValue(accessibilityValue(for: option))
            }
        }
        .padding(3)
        .background(ColorPalette.ink.opacity(0.05), in: Capsule())
        .padding(.top, Self.savingLift)
        .animation(Motion.tap, value: period)
    }

    private func accessibilityValue(for option: BillingPeriod) -> String {
        guard option == .yearly, let saving else { return "" }
        return String(localized: "Save \(saving) percent")
    }
}

#Preview {
    PaywallView(onDismiss: {})
        .environment(StoreManager())
        .preferredColorScheme(.dark)
}
