import MacCastKit
import StoreKit
import SwiftUI

extension View {
    /// **Attached in more than one place, and it has to be, which is the whole reason this is a
    /// modifier rather than a `.sheet` written out where it is needed.** A sheet can only be
    /// presented by a view that is not already presenting one. This app puts locks inside sheets:
    /// the terminal is a sheet, and its deck, its quick commands and the file browser all carry one.
    /// A paywall presented from the root while the terminal is up is a presentation UIKit refuses
    /// in silence, and the failure looks exactly like the app ignoring the tap.
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
    enum Reason {
        case quotaExhausted
        case upgrade
        case firstSession
        case runningLow(remaining: TimeInterval)
        case feature(PlanCapability)

        var title: String {
            switch self {
            case .quotaExhausted: return String(localized: "Keep going from anywhere")
            case .upgrade: return String(localized: "Connect from anywhere")
            case .firstSession: return String(localized: "Take it with you")
            case .runningLow: return String(localized: "Running low on relay time")
            case .feature(let capability): return String(localized: "Unlock \(capability.name)")
            }
        }

        func detail(for plan: RelayPlan) -> String {
            switch self {
            case .feature(let capability):
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
                case .relay, .pro:
                    // Unreachable as the app is wired: paid plans are unlimited and never metered,
                    // so the relay cannot refuse one for quota. True rather than blank.
                    return String(localized: "The relay counted this connection against a quota your plan does not have. Try again, and tell us if it keeps happening.")
                }
            case .upgrade:
                return String(localized: "Reaching a Mac on another network runs on the relay, which is metered. Free includes \(RelayPlan.free.allowanceSpelling) a day. Any paid plan removes the limit.")
            case .firstSession:
                let moment = String(localized: "That was your first session. Relay is the part of Peering that reaches your Mac when this device is not on the same network.")
                switch plan {
                case .free:
                    return String(localized: "\(moment) Free includes \(RelayPlan.free.allowanceSpelling) of relay a day. Any paid plan removes the limit.")
                case .relay:
                    return String(localized: "\(moment) You are already subscribed, so there was no meter on this one.")
                case .pro:
                    return String(localized: "\(moment) Your plan already includes unlimited relay, so there is nothing here to buy.")
                }
            case .runningLow(let remaining):
                let left = RelayTime.label(remaining)
                switch plan {
                case .free:
                    return String(localized: "\(left) left today. When it runs out, reaching a Mac on another network stops until the allowance comes back. Any paid plan removes the limit.")
                case .relay, .pro:
                    // Unreachable as the app is wired: paid plans are unlimited, so
                    // ``SessionModel/relaySecondsRemainingEstimate`` is `nil` for them and nothing
                    // can construct this reason. True rather than blank.
                    return String(localized: "\(left) left of today's relay time.")
                }
            }
        }

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
                return String(localized: "A sharper picture when the session is relayed. On your own network it is already uncapped on every plan.")
            case .agentChat:
                return String(localized: "Your coding agents as a conversation: their replies, the tools they run and the files they touch drawn natively, with an approve button where the agent asks. Running them in the terminal is on every plan.")
            }
        }
    }

    @Environment(StoreManager.self) private var store
    var reason: Reason = .upgrade
    var onDismiss: () -> Void

    @State private var chosen: StoreManager.Tier = .pro

    @State private var period: BillingPeriod = .monthly
    @State private var showsEverythingIncluded = false

    /// Deliberately not `store.activeTier`, which is also non-nil for somebody who subscribed last
    /// month and opened this sheet through the upgrade door: a confirmation shown to them is a
    /// screen that has stopped offering anything. Only a purchase that happened here, or a plan
    /// that became active while this sheet was open, sets this.
    @State private var justBought: StoreManager.Tier?

    @State private var awaitingApproval = false

    @State private var restoreNote: String?

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
    }

    // MARK: - Sections

    private var header: some View {
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

    private var footer: some View {
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
}

// MARK: - The session the relay ended

/// **The one ending that has nothing on screen to explain it.** Every other way a session stops
/// says so somewhere: the Mac locked, the network went, the user tapped End. This one is a socket
/// closing. The relay ends a session the moment its window is spent, and it has nowhere to say
/// why: everything past the session token is a TLS connection it cannot write into, and the
/// signalling socket is a different connection that may already be closed. What the user sees is
/// their Mac vanishing, then a reconnect that is refused, and nothing anywhere about money.
struct AllowanceSpentView: View {
    let plan: RelayPlan
    let onDismiss: () -> Void

    @Environment(StoreManager.self) private var store

    /// Presented from inside here rather than by closing this and setting the session's
    /// ``SessionModel/paywallReason``, which is how every other door opens it. Two sheets on one
    /// view cannot cross in the same update (the dismissal and the presentation race), and a
    /// nested sheet is the shape that does not.
    @State private var showsPlans = false

    var body: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()
            TopGlow()

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

    private var title: String {
        switch plan {
        case .free: return String(localized: "Your free relay time is used up")
        case .relay, .pro:
            // Unreachable as the app is wired: paid plans are unlimited and never cut for quota.
            // True rather than blank, like the paywall's own unreachable branches.
            return String(localized: "The relay stopped the session")
        }
    }

    private var detail: String {
        let stillFree = String(localized: "Your own network is unlimited on every plan, and still works.")
        switch plan {
        case .free:
            return String(localized: "That session went over the relay, and free's \(plan.allowanceSpelling) a day are spent. Another relayed session is refused until the allowance comes back. \(stillFree)")
        case .relay, .pro:
            return String(localized: "Your plan has no daily limit, so the relay counting this one means it read the device as free. Try again, and tell us if it keeps happening. \(stillFree)")
        }
    }
}

// MARK: - Legal

enum Legal {
    static let privacy = URL(string: "https://getpeering.app/privacy")!
    static let terms = URL(string: "https://getpeering.app/terms")!
}

// MARK: - Plan card

private struct PlanCard: View {
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

struct BillingPeriodPicker: View {
    @Binding var period: BillingPeriod
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
