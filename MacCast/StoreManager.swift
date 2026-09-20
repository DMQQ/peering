import Foundation
import MacCastKit
import Security
import StoreKit
import os

private let storeLog = Logger(subsystem: "pl.dmq.peering", category: "store")

// ``RelayPlan`` is no longer here. It is the ladder the feature map is keyed on, so it lives beside
// that map in `MacCastKit`, where the map's answers can be run: a ladder in the app target and a map
// in a package would be two orderings of the same four rungs, kept in step by hand. What stays here
// is everything that is about *buying* rather than about *plans*: the products, the prices, the
// receipts, and the one bridge from an entitlement to the value every gate in the app asks.

/// How often a plan is billed.
///
/// **Every tier is sold both ways, and that is a decision rather than a completeness.** The ladder
/// used to sell one tier monthly and the one above it yearly, which made the comparison on the
/// paywall a comparison of the two periods rather than of the two plans: the middle rung cost
/// £179.88 over a year and the top one cost £39.99, so the middle was not a worse plan, it was a
/// worse *deal*, and the price a user actually paid depended on which card they happened to read
/// first. With a period on every card, the choice is "this plan, monthly or yearly" and the yearly
/// is the one the monthly exists to make look good.
///
/// The monthly is the low-commitment way in and is deliberately the poorer value, at roughly eight
/// months of it to the year. That is the ratio the field uses, and it is the reason to have a
/// monthly at all: not to be bought, but to be the price the yearly is measured against.
nonisolated enum BillingPeriod: String, CaseIterable, Identifiable, Sendable {
    case monthly
    case yearly

    var id: String { rawValue }

    /// The tier's own name for it inside a product identifier: `…relay.monthly`, `…relay.year`.
    ///
    /// `year` rather than `yearly` because that is what the identifiers already used, and a store
    /// identifier that changes is a product that has to be recreated rather than edited.
    var identifier: String {
        switch self {
        case .monthly: return "monthly"
        case .yearly: return "year"
        }
    }

    /// The word the price lines are built from: "£3.99 / month".
    var name: String {
        switch self {
        case .monthly: return "month"
        case .yearly: return "year"
        }
    }

    /// The same word, short enough to sit inside a buy button: "£3.99/mo".
    var shortName: String {
        switch self {
        case .monthly: return "mo"
        case .yearly: return "yr"
        }
    }

    /// What the App Store calls the period, for the sentence under the buy button.
    var storeName: String {
        switch self {
        case .monthly: return "monthly"
        case .yearly: return "yearly"
        }
    }
}

@Observable
@MainActor
final class StoreManager {
    /// The stem every product identifier starts with, in one place.
    ///
    /// `nonisolated` because ``Tier`` and ``BillingPeriod`` are not main-actor types and could not
    /// otherwise build an identifier: those are strings that never change, and the actor that owns
    /// the purchase machinery has no business owning them.
    nonisolated static let productIDStem = "pl.dmq.peering"

    /// Everything that means paid, in one place.
    ///
    /// Asked as a set rather than as a chain of comparisons at each of the three places that
    /// wondered whether the user had bought something, because the day a fourth product arrives
    /// is the day one of those three is missed. Built by walking the tiers and the periods rather
    /// than typed out, for the same reason one step further on: a set written by hand is a set
    /// that stops being complete the first time a period is added.
    nonisolated static let paidProductIDs: Set<String> = Set(
        Tier.allCases.flatMap { tier in
            BillingPeriod.allCases.map { tier.productID(for: $0) }
        }
    )

    private(set) var products: [Product] = []
    /// The tier the user has actually paid for, or `nil` when they have paid for nothing.
    ///
    /// One tier rather than a set of live entitlements, and the best of them rather than the first
    /// found: more than one can be live at once — someone who bought Relay and then moved up to Pro
    /// holds both until the first lapses — and the plan the app states to the relay has to be the
    /// one they are paying the most for. The relay meters, so guessing low here meters a subscriber
    /// rather than granting them something.
    private(set) var activeTier: Tier?
    /// Whether anything at all has been bought.
    ///
    /// **Not what a gate asks.** It is `false` both for a user who has bought nothing and for the
    /// moment before `Transaction.currentEntitlements` has answered, and a gate that read it would
    /// spend that moment showing a padlock to somebody who is paying. ``access`` is the question to
    /// ask; this is here for the two places that want a plain "have they bought anything": the API
    /// key the relay is offered, and the store's own reporting.
    var isPro: Bool { activeTier != nil }
    /// The plan this app states to the relay — free for anyone who has bought nothing.
    var relayPlan: RelayPlan { activeTier?.plan ?? .free }

    /// Whether the App Store has answered the entitlement question yet.
    ///
    /// **A flag of its own rather than `activeTier != nil`**, because those are two different
    /// facts and only one of them can be read off the other. `activeTier` is `nil` both for "this
    /// account has bought nothing" and for "nobody has asked yet", and the whole of the
    /// no-flash rule is the difference between them: see ``PlanAccess``.
    private(set) var hasReadEntitlement = false

    /// What the gates ask: the plan, or the fact that it is not known yet.
    ///
    /// `unknown` rather than a default of free until ``refreshEntitlement()`` has run, and read
    /// off the *entitlement* rather than off ``products``, which is a network fetch that can
    /// answer a minute late, or never, on a plane or before App Store Connect has the products.
    var access: PlanAccess { hasReadEntitlement ? .known(relayPlan) : .unknown }
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
    /// **Three rungs, and each one is a different bargain rather than more of the last.** Relay is
    /// the remote working set: three hours a day, every Mac you own, sound, Picture in Picture,
    /// wake on LAN, and files moving both ways. Relay Plus is the clock going away. Pro is the
    /// toolbox and the funder, which is the rung somebody buys to have the tool rather than to run
    /// out of it.
    ///
    /// **They used to be a decoy ladder and that was the problem.** The middle rung cost more over
    /// a year than the top one, because the middle was priced monthly and the top yearly, so the
    /// comparison on the paywall was between two periods rather than two plans and the price a user
    /// paid came down to which card they read first. Every tier is now sold at both periods, at
    /// roughly eight months of the monthly to the year, so the monthly is what the yearly is
    /// measured against instead of what the middle rung silently was.
    ///
    /// The copy is here and not in App Store Connect because the two are different things. What the
    /// store holds is what the products are *called*; this is what each one is *for*, in the app's
    /// own words and in its own order, and it is the app's because the app is where the comparison
    /// is made. Prices are the one exception and always come from the store — a price written into
    /// the app is a price that is wrong in every country but one.
    /// `nonisolated` on the whole type, because every one of these is a string that never changes:
    /// a tier's identifier, what it is called, what it costs and what the store product is called.
    /// The isolation they would otherwise inherit is the store's, and the store is the actor that
    /// owns the purchase machinery — which has no business owning the words on the cards, and
    /// which is what stopped ``paidProductIDs`` from being written by walking the two enums.
    nonisolated enum Tier: String, CaseIterable, Identifiable {
        case relay
        case relayPlus
        case pro

        var id: String { rawValue }

        /// The tier's own name inside a product identifier, which is not `rawValue`.
        ///
        /// `relayPlus` is `plus` here because identifiers are typed into App Store Connect by hand
        /// and a camel case word in the middle of a dotted identifier is a typo waiting to happen.
        /// The relay's plan names happen to agree with these, and that is a coincidence rather than
        /// a dependency: ``plan`` is the thing that decides what the relay meters by.
        var identifier: String {
            switch self {
            case .relay: return "relay"
            case .relayPlus: return "plus"
            case .pro: return "pro"
            }
        }

        /// The store product for this tier at a given period.
        ///
        /// **Two products per tier, not one per tier and one per period somewhere else.** The
        /// monthly and the yearly of the same plan sit at the same level in the same subscription
        /// group, which is what makes moving between them an upgrade or a downgrade rather than a
        /// second subscription, and what stops somebody holding both at once.
        func productID(for period: BillingPeriod) -> String {
            "\(StoreManager.productIDStem).\(identifier).\(period.identifier)"
        }

        /// The tier whose products are in a set of entitled product IDs, or `nil` for none.
        ///
        /// The highest rather than the first, and `allCases` is in the order the ladder is shown,
        /// cheapest first, so a user holding two entitlements gets the one they are paying more for.
        /// Picking the other way round would meter somebody who has bought Pro as if they were on
        /// Relay.
        ///
        /// **Matched on the tier inside the identifier rather than on a whole product id.** There
        /// are two ids per tier now, and a table of them written out here would drop a yearly
        /// subscriber to the free allowance the moment they renewed, which is the kind of mistake
        /// that shows up as a support email rather than as a test failure.
        static func named(by productID: String) -> Tier? {
            let parts = productID.split(separator: ".")
            guard parts.count >= 2 else { return nil }
            return allCases.first { $0.identifier == String(parts[parts.count - 2]) }
        }

        static func best(of productIDs: Set<String>) -> Tier? {
            allCases.last { tier in
                productIDs.contains { named(by: $0) == tier }
            }
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
                return "\(plan.allowanceSpelling.capitalized) of relay a day, on every Mac you own."
            case .relayPlus: return "No limit on relay, and the tools that come with it."
            case .pro: return "No limit on relay, and the whole toolbox."
            }
        }

        /// How many Macs a paid plan pairs with, in the words the plan screens use.
        ///
        /// **One answer for all three, because the number of Macs somebody owns is not a measure of
        /// what they get out of this app.** TeamViewer, RealVNC, AnyDesk and Splashtop all gate the
        /// device count, and it is the field's favourite axis; it is also the one thing here that
        /// costs nothing to serve, which is why it belongs on the cheapest rung rather than being
        /// sold back three times. Free is the rung that differs, at a single Mac, and it is the
        /// pairing screen's rule to state.
        ///
        /// **Enforced at the pairings, by ``PlanCapability/extraMacs``.** A free user pairs one
        /// Mac; the second is drawn with a lock and opens the paywall, which is the honest shape
        /// for a limit on a list rather than on a control. What that costs is a limit the client
        /// keeps rather than the server, which is the trust level the whole map is kept at.
        static let macCount = "Every Mac"

        var features: [String] {
            switch self {
            case .relay:
                return [
                    "\(plan.allowanceSpelling.capitalized) of relay every day",
                    "Every Mac you own instead of one",
                    "Sound from the Mac, and Picture in Picture",
                    "Moving files between the phone and the Mac",
                    "Everything free has, and all of it stays free",
                ]
            case .relayPlus:
                return [
                    "Everything in Relay",
                    "Unlimited relay time",
                    "Several shells at once, as tabs",
                ]
            case .pro:
                return [
                    "Everything in Relay Plus",
                    "Macros, snippets and quick commands",
                    "The sharpest picture over the relay",
                    "Every feature added while you are subscribed",
                ]
            }
        }

        /// The tier the screen opens on, and the one the badge goes on.
        var isRecommended: Bool { self == .pro }
    }

    /// The store's product for a tier at a period, or `nil` while the store has not answered.
    func product(for tier: Tier, period: BillingPeriod) -> Product? {
        products.first { $0.id == tier.productID(for: period) }
    }

    /// A tier's whole price in one string: "£3.99 / month", or "£29.99 / year".
    ///
    /// Built here rather than at each screen because two screens print it now, the paywall and the
    /// last page of the introduction, and a period spelled "/ month" on one and "per month" on the
    /// other is the kind of difference that makes a fetched price look hand-typed.
    func priceLabel(for tier: Tier, period: BillingPeriod) -> String? {
        guard let product = product(for: tier, period: period) else { return nil }
        return "\(product.displayPrice) / \(period.name)"
    }

    /// The same price, short enough to sit inside the buy button: "£3.99/mo".
    ///
    /// Shorter, and only shorter. "Continue with Relay Plus, £7.99 / month" is a button that wraps
    /// on a small phone, and a price that has wrapped is a price that was not read. The money is
    /// the same string either way; only the spelling of the period changes.
    func compactPriceLabel(for tier: Tier, period: BillingPeriod) -> String? {
        guard let product = product(for: tier, period: period) else { return nil }
        return "\(product.displayPrice)/\(period.shortName)"
    }

    /// What the yearly works out at per month, in the store's own currency: "$2.50".
    ///
    /// **The number that makes a yearly price legible.** "$29.99 a year" is a sum, and a sum is what
    /// the user has to divide by twelve in their head before it can be compared with anything. This
    /// is the same money already divided, and it sits directly under the yearly price on the card,
    /// which is the only place it means anything: beside the monthly price it would be the yearly
    /// arguing for itself.
    ///
    /// Rounded by the currency formatter rather than by hand, because a price is a Decimal and
    /// `Decimal` division does not produce the number a person would write down. The formatter also
    /// knows the storefront's currency and where its symbol goes, which a hand-built string does not.
    func effectiveMonthlyPrice(for tier: Tier) -> String? {
        guard let yearly = product(for: tier, period: .yearly) else { return nil }
        return (yearly.price / 12).formatted(yearly.priceFormatStyle)
    }

    /// The smallest yearly saving on offer, for the one place a single number stands for all three.
    ///
    /// The paywall prints it once on the period switch, and that switch applies to every plan, so
    /// the number has to be true of all of them. The three land within a couple of points of each
    /// other; the smallest is the one that is still honest when the user picks the card it is least
    /// true of. `nil` until the store has answered with both periods for at least one tier, because
    /// a saving printed beside a price that never arrived is a claim the screen cannot back.
    var smallestYearlySaving: Int? {
        Tier.allCases.compactMap { yearlySaving(for: $0) }.min()
    }

    /// What the yearly costs against the monthly, as a whole-number percentage saved: "33%".
    ///
    /// **Computed from the two prices rather than written down**, and `nil` unless both have been
    /// fetched: a discount printed beside a price that never arrived is a claim the card cannot
    /// back. Rounded down rather than to nearest, because the number is a promise about money and
    /// the smaller of the two roundings is the one that is still true.
    func yearlySaving(for tier: Tier) -> Int? {
        guard let monthly = product(for: tier, period: .monthly),
              let yearly = product(for: tier, period: .yearly) else { return nil }
        let monthlyCents = (monthly.price * 100 as NSDecimalNumber).doubleValue
        let yearlyCents = (yearly.price * 100 as NSDecimalNumber).doubleValue
        guard monthlyCents > 0, yearlyCents > 0 else { return nil }
        let full = monthlyCents * 12
        guard yearlyCents < full else { return nil }
        return Int(((full - yearlyCents) / full * 100).rounded(.down))
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
            // user has to find again. Within a tier the monthly comes first, which is the order
            // the two are read in on the card that carries both.
            products = Tier.allCases.flatMap { tier in
                BillingPeriod.allCases.compactMap { period in
                    loaded.first { $0.id == tier.productID(for: period) }
                }
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
            // Read off the identifier's middle word rather than matched against a table of whole
            // ids: there are two per tier, and a table that knew about only one of them would
            // leave a yearly subscriber looking like somebody who has bought nothing.
            guard let tier = Tier.named(by: transaction.productID) else { continue }
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
        // Set here and nowhere else, because this is the one place the question is answered. The
        // loop above runs to its end even when there is nothing live: "this account has bought
        // nothing" is an answer, and it is the one that must unlock the gates' own locks rather
        // than leave them waiting. See ``PlanAccess``.
        hasReadEntitlement = true
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
