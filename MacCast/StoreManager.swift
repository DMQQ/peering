import Foundation
import Security
import StoreKit
import os

private let storeLog = Logger(subsystem: "pl.dmq.peering", category: "store")

/// The plan this app states on the relay, and the one place the app writes down what each plan
/// allows.
///
/// **The statement is a claim, and the proof travels beside it.** What the relay meters by is the
/// JWS StoreKit signed for the live transaction (``StoreManager/activeJWS``), which the relay
/// verifies against Apple's published root and which names the product — so a modified app that
/// says `plus` without one is metered by the plan it claims only for as long as the relay keeps
/// believing claims at all. The relay's `storekit.rs` holds that reasoning and the condition for
/// ending it; the short version is that reading an unproven `plus` as free on the day the
/// verification shipped would have taken every existing subscriber down to half an hour a day,
/// which is why the claim still decides anything at all.
///
/// **The numbers are the relay's, repeated here.** `Relay/src/config.rs` holds the authority —
/// thirty minutes free and three hours on Relay, both per rolling 24-hour window, and no limit at
/// all above that (`PEERINGD_FREE_MINUTES`, `PEERINGD_RELAY_MINUTES`). This mirrors them so the bar
/// in the Sessions tab can be drawn without asking the server, and the copy in ``Tier``,
/// `PaywallView`, `OnboardingView` and `Relay/site` states the same facts again. Edit one without
/// the others and the bar lies about the allowance it is drawing.
enum RelayPlan: String, CaseIterable, Sendable {
    case free
    case relay
    case plus
    case pro

    /// Seconds of relay this plan allows in one window, or `nil` for no limit.
    ///
    /// `nil` is the absence of a number rather than a very large one, which is the distinction the
    /// relay makes too: an unlimited plan is not metered, so there is nothing to count and no bar
    /// to draw. It is also why this is not an optional the caller has to guess the meaning of —
    /// ``isUnlimited`` says which it is.
    var allowanceSeconds: TimeInterval? {
        switch self {
        case .free: return 30 * 60
        case .relay: return 180 * 60
        case .plus, .pro: return nil
        }
    }

    var isUnlimited: Bool { allowanceSeconds == nil }

    /// The allowance in the app's own words, for the copy that names it.
    ///
    /// Here rather than typed into four screens: "three hours" written beside a number that says
    /// 18,000 seconds is the drift this file exists to prevent, and a sentence assembled from this
    /// cannot disagree with the bar.
    var allowanceSpelling: String {
        switch self {
        case .free: return "half an hour"
        case .relay: return "three hours"
        case .plus, .pro: return "unlimited relay"
        }
    }
}

@Observable
@MainActor
final class StoreManager {
    /// `nonisolated` on all four because ``Tier`` is not a main-actor type and could not otherwise
    /// name them — the identifiers are strings that never change, and the actor that owns the
    /// purchase machinery has no business owning them.
    nonisolated static let monthlyID = "pl.dmq.peering.relay.monthly"
    nonisolated static let plusID = "pl.dmq.peering.relayplus.monthly"
    nonisolated static let yearID = "pl.dmq.peering.relay.year"

    /// Everything that means paid, in one place.
    ///
    /// Asked as a set rather than as a chain of comparisons at each of the three places that
    /// wondered whether the user had bought something, because the day a fourth product arrives
    /// is the day one of those three is missed.
    nonisolated static let paidProductIDs: Set<String> = [monthlyID, plusID, yearID]

    private(set) var products: [Product] = []
    /// The tier the user has actually paid for, or `nil` when they have paid for nothing.
    ///
    /// One tier rather than a set of live entitlements, and the best of them rather than the first
    /// found: more than one can be live at once — someone who bought Relay and then moved up to Pro
    /// holds both until the first lapses — and the plan the app states to the relay has to be the
    /// one they are paying the most for. The relay meters, so guessing low here meters a subscriber
    /// rather than granting them something.
    private(set) var activeTier: Tier?
    /// Whether anything at all has been bought. What the app's own feature gating asks.
    var isPro: Bool { activeTier != nil }
    /// The plan this app states to the relay — free for anyone who has bought nothing.
    var relayPlan: RelayPlan { activeTier?.plan ?? .free }
    /// The signed transaction for whatever ``activeTier`` is, or `nil` when there is nothing to
    /// prove.
    ///
    /// This is the part the relay believes: it verifies the JWS against Apple's published root and
    /// meters by the product the receipt names, so a device that reaches the relay with this set is
    /// on the plan it paid for whatever the app claims beside it. It is `nil` for a user who has
    /// bought nothing, and briefly at launch — the receipts come from `Transaction.currentEntitlements`
    /// in ``start()``, and until that answers the relay has only the claim to go on. See the note
    /// on ``RelayPlan`` for what that costs and what it is worth.
    private(set) var activeJWS: String?
    var isPurchasing = false
    var purchaseError: String?
    /// Whether the last attempt to fetch prices came back with nothing.
    ///
    /// Kept apart from an empty ``products`` on purpose, because those two are different states
    /// that look identical from the outside: one means the fetch is still in flight, the other
    /// means it finished and the App Store returned no such products — which is what happens on
    /// every launch until the products exist in App Store Connect, and in the simulator unless the
    /// scheme carries a StoreKit configuration. Without the distinction the paywall showed a
    /// spinner that never stopped, which is worse than an error: it looks like the app is thinking.
    private(set) var productsUnavailable = false

    init() {
        Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handleVerification(result)
            }
        }
    }

    /// The API key sent to the relay beside the plan.
    ///
    /// A UUID minted once and kept in the Keychain, and it is *not* a credential: the relay holds a
    /// server-side list of keys that grant unlimited relay (`PEERINGD_PAID_KEYS`) and nothing can
    /// add this to it, so it matches nothing and grants nothing. It travels anyway because that
    /// list is one of the two grants the relay does not take a client's word for, and a device that
    /// never says its key cannot be put on it. The other is the receipt — see
    /// ``StoreManager/activeJWS`` — and what decides the allowance when neither applies is
    /// ``relayPlan``, the app's claim about what it bought.
    var apiKey: String? {
        guard isPro else { return nil }
        return persistedKey()
    }

    func start() async {
        await refreshEntitlement()
        await fetchProducts()
    }

    /// What a purchase came to, for the screen that started it.
    ///
    /// **The screen used to be told nothing.** `purchase` returned `Void`, so the paywall could
    /// not tell a completed purchase from a cancelled one, a deferred one or a failure, and it
    /// did what a screen with no answer does: it stayed exactly as it was. A user who had just
    /// paid was left looking at the same ladder and the same buy button as a user who had not.
    enum PurchaseOutcome: Sendable, Equatable {
        /// The App Store took the money and the transaction verified.
        case purchased
        /// Sent for approval: Ask to Buy, or a bank check. Neither a failure nor yet a purchase.
        case pending
        /// The user backed out, or dismissed the sheet.
        case cancelled
        /// Refused by the store, or completed and not verifiable. `purchaseError` carries the
        /// sentence in both cases.
        case failed
    }

    @discardableResult
    func purchase(_ product: Product) async -> PurchaseOutcome {
        isPurchasing = true
        purchaseError = nil
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard await handleVerification(verification) else {
                    // **The one failure that must never be silent.** The money has left the
                    // account, the app has unlocked nothing, and this used to return without a
                    // word: the buy button simply came back. The sentence says what to do about
                    // it, and the button below it is Restore.
                    purchaseError = "The App Store could not confirm that purchase. If you were charged, use Restore purchases, and get in touch if that does not bring it back."
                    return .failed
                }
                return .purchased
            case .pending:
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .cancelled
            }
        } catch {
            purchaseError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            storeLog.error("purchase failed: \(error, privacy: .public)")
            return .failed
        }
    }

    /// Whether a plan is live once the App Store has answered.
    ///
    /// The answer rather than `Void`, because "restored nothing" and "restored something" are the
    /// two outcomes the button's own screen has to distinguish, and it has no other way to know:
    /// the error it used to write goes to a surface that does not exist in the state that tells
    /// people to restore.
    @discardableResult
    func restore() async -> Bool {
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            return activeTier != nil
        } catch {
            purchaseError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    // MARK: - Tiers

    /// What there is to buy, in the order it is shown.
    ///
    /// Three tiers, and the middle one is there to be compared rather than chosen. `relayPlus` costs
    /// nearly what `pro` costs and does a fraction of what it does, which is what makes `pro` read
    /// as the obvious answer — the step that exists to be stepped over. It is a real product at a
    /// real price that does everything it claims, which is the only kind of decoy worth having: one
    /// that is merely *worse value* rather than misleading about what it is.
    ///
    /// The billing periods are what make that work. `relayPlus` is priced monthly and `pro` yearly,
    /// so comparing what the two cost over a year is a comparison `pro` wins by a wide margin — and
    /// the monthly plans are still there for somebody who wants to try this for one month and stop.
    ///
    /// The copy is here and not in App Store Connect because the two are different things. What the
    /// store holds is what the products are *called*; this is what each one is *for*, in the app's
    /// own words and in its own order, and it is the app's because the app is where the comparison
    /// is made. Prices are the one exception and always come from the store — a price written into
    /// the app is a price that is wrong in every country but one.
    enum Tier: String, CaseIterable, Identifiable {
        case relay
        case relayPlus
        case pro

        var id: String { rawValue }

        var productID: String {
            switch self {
            case .relay: return StoreManager.monthlyID
            case .relayPlus: return StoreManager.plusID
            case .pro: return StoreManager.yearID
            }
        }

        /// The tier whose products are in a set of entitled product IDs, or `nil` for none.
        ///
        /// The highest rather than the first, and `allCases` is in the order the ladder is shown,
        /// cheapest first — so a user holding two entitlements gets the one they are paying more
        /// for. Picking the other way round would meter somebody who has bought Pro as if they were
        /// on Relay.
        static func best(of productIDs: Set<String>) -> Tier? {
            allCases.last { productIDs.contains($0.productID) }
        }

        /// The plan this tier is sold as, which is the name the relay meters by.
        ///
        /// The two names differ where the product and the plan do — Relay Plus is `plus` on the
        /// wire — and the relay treats `plus` and `pro` the same, since what separates them is how
        /// many Macs they pair with rather than how much relay they buy.
        var plan: RelayPlan {
            switch self {
            case .relay: return .relay
            case .relayPlus: return .plus
            case .pro: return .pro
            }
        }

        var name: String {
            switch self {
            case .relay: return "Relay"
            case .relayPlus: return "Relay Plus"
            case .pro: return "Pro"
            }
        }

        /// The one line under the name, which is what the tier is *for*.
        ///
        /// The allowance is read off ``RelayPlan`` rather than typed in, so what a card promises and
        /// what the relay meters are the same number. That matters most for the middle rung: it is
        /// the one a subscriber compares against free, and "three hours" appearing on the card
        /// while the meter beside it counts half an hour is how a sale turns into a refund.
        var tagline: String {
            switch self {
            case .relay:
                return "\(plan.allowanceSpelling.capitalized) of relay a day, on one Mac."
            case .relayPlus: return "Unlimited relay, two Macs, terminals and widgets."
            case .pro: return "Every Mac and every feature, billed once a year."
            }
        }

        /// How many Macs this plan pairs with, in the words the plan screens use.
        ///
        /// **Stated here and not enforced anywhere yet**, which is the same position the whole gate
        /// map is in: the app meters relay time and nothing else, and the plan screens describe the
        /// ladder that is being built rather than the one the code already keeps. It lives beside
        /// ``tagline`` because that is where the two Macs were first claimed, and because a number
        /// written into one screen and not the other is the drift this file exists to prevent.
        ///
        /// The free plan is the one that makes this awkward, and saying so is more honest than
        /// leaving it blank: it pairs with as many Macs as the paid plans do today, so the row
        /// below describes where the limit is going rather than where it is.
        var macCount: String {
            switch self {
            case .relay: return "1 Mac"
            case .relayPlus: return "2 Macs"
            case .pro: return "Every Mac"
            }
        }

        var features: [String] {
            switch self {
            case .relay:
                return [
                    "\(plan.allowanceSpelling.capitalized) of relay every day, on one Mac",
                    "Everything free has: LAN sessions, clipboard, session history",
                ]
            case .relayPlus:
                return [
                    "Unlimited relay time",
                    "Everything in Relay",
                    "Two Macs instead of one",
                    "Terminal sessions",
                    "Live Activities and widgets",
                ]
            case .pro:
                return [
                    "Everything in Relay Plus",
                    "Every Mac you own",
                    "Every display and every window as a source",
                    "Snippets, quick commands and macros",
                    "Session audio, and Picture in Picture",
                    "Wake on LAN, and privacy mode",
                    "Everything added while you are subscribed",
                ]
            }
        }

        /// Whether the money comes out every month or every year, in the two spellings the two
        /// places that print a price need.
        ///
        /// A word rather than a flag now that all three are subscriptions. What separates them is
        /// the period, and a boolean cannot say which one.
        var period: String {
            switch self {
            case .relay, .relayPlus: return "month"
            case .pro: return "year"
            }
        }

        var shortPeriod: String {
            switch self {
            case .relay, .relayPlus: return "mo"
            case .pro: return "yr"
            }
        }

        /// The tier the screen opens on, and the one the badge goes on.
        var isRecommended: Bool { self == .pro }
    }

    /// The store's product for a tier, or `nil` while the store has not answered.
    func product(for tier: Tier) -> Product? {
        products.first { $0.id == tier.productID }
    }

    /// A tier's whole price in one string: "£4.99 / month", or "£79.99".
    ///
    /// Built here rather than at each screen because two screens print it now — the paywall and the
    /// last page of the introduction — and a period spelled "/ month" on one and "per month" on the
    /// other is the kind of difference that makes a fetched price look hand-typed.
    func priceLabel(for tier: Tier) -> String? {
        guard let product = product(for: tier) else { return nil }
        return "\(product.displayPrice) / \(tier.period)"
    }

    /// The same price, short enough to sit inside the buy button: "£4.99/mo".
    ///
    /// Shorter, and only shorter. "Continue with Relay Plus — £14.99 / month" is a button that
    /// wraps on a small phone, and a price that has wrapped is a price that was not read. The
    /// money is the same string either way; only the spelling of the period changes.
    func compactPriceLabel(for tier: Tier) -> String? {
        guard let product = product(for: tier) else { return nil }
        return "\(product.displayPrice)/\(tier.shortPeriod)"
    }

    // MARK: - Private

    private func fetchProducts() async {
        // Cleared first, so a retry from an empty state goes back to the spinner rather than
        // leaving the failure on screen while the second attempt is still running.
        productsUnavailable = false
        do {
            let loaded = try await Product.products(for: Array(Self.paidProductIDs))
            // Put back into the order the tiers are sold in rather than the order the store
            // answers in, which is by price and therefore moves the day a price changes. A card
            // that swaps places with its neighbour after an App Store price edit is a card the
            // user has to find again.
            products = Tier.allCases.compactMap { tier in
                loaded.first { $0.id == tier.productID }
            }
            // An empty answer is not a slow one. The store has spoken.
            productsUnavailable = products.isEmpty
        } catch {
            storeLog.error("product fetch failed: \(error, privacy: .public)")
            productsUnavailable = true
        }
    }

    /// Asks the App Store what this device is currently entitled to, and keeps the receipt along
    /// with the answer.
    ///
    /// The two are collected together because they are one fact: the JWS is Apple's signature over
    /// *this* transaction, so the receipt that travels to the relay has to be the one belonging to
    /// the tier that wins. Holding them apart is how a device with two live subscriptions sends
    /// proof of the cheaper one and is metered for it.
    ///
    /// `verification` is checked here as well as by the relay, and for a different reason: this one
    /// decides what the app unlocks on the device, and an unverified transaction is one this
    /// process cannot vouch for at all. The relay checks it again because the relay cannot trust
    /// anything this process says — see ``RelayEntitlement``.
    private func refreshEntitlement() async {
        /// The signed transaction each live entitlement came with, by the tier it buys.
        var live: [Tier: String] = [:]
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard let tier = Tier.allCases.last(where: { $0.productID == transaction.productID })
            else { continue }
            guard transaction.revocationDate == nil else { continue }
            // Off the `VerificationResult` rather than off the transaction it wraps, which is where
            // StoreKit puts it: the JWS is Apple's signature over this result, and reading it from
            // the result that has just been checked is the only way to be sure the two belong
            // together.
            live[tier] = result.jwsRepresentation
            await transaction.finish()
        }

        // The best of them rather than the first, in the order the ladder is shown: more than one
        // can be live at once — someone who bought Relay and then moved up to Pro holds both until
        // the first lapses — and the plan stated to the relay has to be the one they are paying the
        // most for.
        activeTier = Tier.allCases.last { live[$0] != nil }
        activeJWS = activeTier.flatMap { live[$0] }
    }

    /// Applies a transaction the App Store handed over, and says whether it was one Apple signed.
    ///
    /// Deliberately writes no UI state of its own. This is called from the `Transaction.updates`
    /// loop as well as from a purchase, and an error raised by a renewal arriving in the
    /// background would sit on `purchaseError` until somebody opened the paywall for an unrelated
    /// reason and found a complaint about a purchase they did not make.
    @discardableResult
    private func handleVerification(_ result: VerificationResult<Transaction>) async -> Bool {
        switch result {
        case .verified(let tx):
            await tx.finish()
            await refreshEntitlement()
            return true
        case .unverified(_, let error):
            storeLog.error("transaction not verified: \(error, privacy: .public)")
            return false
        }
    }

    // MARK: - Keychain key

    private static let keychainService = "pl.dmq.peering"
    private static let keychainAccount = "relayApiKey"

    private func persistedKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let key = String(data: data, encoding: .utf8) {
            return key
        }
        let key = UUID().uuidString
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: Data(key.utf8),
        ]
        SecItemAdd(attrs as CFDictionary, nil)
        return key
    }
}
