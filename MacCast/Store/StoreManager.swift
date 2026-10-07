import Foundation
import MacCastKit
import RemoteCore
import Security
import StoreKit
import os

private let storeLog = Logger(subsystem: "pl.dmq.peering", category: "store")

// RelayPlan lives in MacCastKit beside the feature map so the map's answers can be tested; this file is about buying.

/// How often a plan is billed. Every tier is sold both ways so the paywall compares plans, not periods; monthly is roughly eight months to the year.
nonisolated enum BillingPeriod: String, CaseIterable, Identifiable, Sendable {
    case monthly
    case yearly

    var id: String { rawValue }

    /// `year`, not `yearly`: the store identifiers already use it and cannot be edited.
    var identifier: String {
        switch self {
        case .monthly: return "monthly"
        case .yearly: return "year"
        }
    }

    var name: String {
        switch self {
        case .monthly: return "month"
        case .yearly: return "year"
        }
    }

    var shortName: String {
        switch self {
        case .monthly: return "mo"
        case .yearly: return "yr"
        }
    }

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
    /// `nonisolated`: ``Tier`` and ``BillingPeriod`` are not main-actor types and must be able to build identifiers.
    nonisolated static let productIDStem = "pl.dmq.peering.iap"

    nonisolated static let paidProductIDs: Set<String> = Set(
        Tier.allCases.flatMap { tier in
            BillingPeriod.allCases.map { tier.productID(for: $0) }
        }
    )

    private(set) var products: [Product] = []
    /// The best live tier, not the first: someone who moved up holds two, and the relay meters, so guessing low meters a subscriber.
    private(set) var activeTier: Tier?
    /// Not what a gate asks: false also before `Transaction.currentEntitlements` has answered. Use ``access``.
    var isPro: Bool { activeTier != nil }
    /// The plan this app states to the relay — free for anyone who has bought nothing.
    var relayPlan: RelayPlan { activeTier?.plan ?? .free }

    /// Separate from `activeTier != nil`: nil means both "bought nothing" and "not asked yet", and the no-flash rule is that difference.
    private(set) var hasReadEntitlement = false

    /// `unknown` until ``refreshEntitlement()`` has run, read from the entitlement and not ``products``, a network fetch that can be late or never answer.
    var access: PlanAccess {
#if DEBUG
        // Ahead of the entitlement: otherwise the override would look untaken for the first moment of every launch.
        if let planOverride { return .known(planOverride) }
#endif
        return hasReadEntitlement ? .known(relayPlan) : .unknown
    }
    /// The signed transaction the relay verifies against Apple's root and meters by. Nil with nothing bought, and briefly at launch.
    private(set) var activeJWS: String?
    var isPurchasing = false
    var purchaseError: String?
    /// Separate from an empty ``products``: that means in flight, this means the store returned nothing (always until products exist in App Store Connect or the scheme has a StoreKit configuration). Without it the paywall spun forever.
    private(set) var productsUnavailable = false

#if DEBUG
    nonisolated static let planOverrideKey = "Peering.developerPlanOverride"

    /// A hand-picked plan for inspecting gates. It changes what the app shows and never what is sent to the relay (``relayPlan`` still reads the real entitlement).
    /// `#if DEBUG`: in install-iphone.sh builds, never in App Store builds.
    private(set) var planOverride: RelayPlan? {
        didSet {
            UserDefaults.standard.set(planOverride?.rawValue, forKey: Self.planOverrideKey)
        }
    }

    func setPlanOverride(_ plan: RelayPlan?) {
        planOverride = plan
        storeLog.notice("""
            developer plan override \(plan?.rawValue ?? "cleared", privacy: .public)
            """)
    }
#endif

    init() {
#if DEBUG
        // Read, not assigned through ``setPlanOverride(_:)``, so loading does not write back.
        planOverride = UserDefaults.standard
            .string(forKey: Self.planOverrideKey)
            .flatMap(RelayPlan.init(rawValue:))
#endif
        Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handleVerification(result)
            }
        }
    }

    /// A UUID kept in the Keychain. Not a credential: it grants nothing unless it is on the relay's server-side paid list (PEERINGD_PAID_KEYS), which nothing here can add it to.
    var apiKey: String? {
        guard isPro else { return nil }
        return persistedKey()
    }

    func start() async {
        await refreshEntitlement()
        await fetchProducts()
    }

    /// Re-reads the entitlement when the app returns to the front. A lapsed subscription produces no transaction, only absence from `currentEntitlements`, so a lapse under a running app kept the old plan armed (Picture in Picture especially).
    /// Asked on the way in because it is a local call and must be true before anything is armed on the way out. One gap remains: a lapse while the app stays foreground.
    func rereadEntitlement() async {
        await refreshEntitlement()
    }

    /// What a purchase came to; the paywall could not tell completed from cancelled, deferred or failed when this returned Void.
    enum PurchaseOutcome: Sendable, Equatable {
        case purchased
        /// Sent for approval: Ask to Buy, or a bank check. Neither a failure nor yet a purchase.
        case pending
        case cancelled
        case failed
    }

    @discardableResult
    func purchase(_ product: Product) async -> PurchaseOutcome {
        isPurchasing = true
        purchaseError = nil
        defer { isPurchasing = false }
        let outcome = await performPurchase(product)
        Analytics.purchaseFinished(outcome: "\(outcome)")
        return outcome
    }

    private func performPurchase(_ product: Product) async -> PurchaseOutcome {
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard await handleVerification(verification) else {
                    // Never silent: the money has left the account and nothing unlocked. The sentence points at Restore.
                    purchaseError = String(localized: "The App Store could not confirm that purchase. If you were charged, use Restore purchases, and get in touch if that does not bring it back.")
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

    /// Returns the outcome because the screen must tell "restored nothing" from "restored something".
    @discardableResult
    func restore() async -> Bool {
        Analytics.featureUsed(.restorePurchases)
        isPurchasing = true
        purchaseError = nil
        defer { isPurchasing = false }
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

    /// What there is to buy, in the order shown.
    /// `nonisolated`: constant strings should not inherit the store actor's isolation. Prices always come from the store, never written into the app.
    nonisolated enum Tier: String, CaseIterable, Identifiable {
        case relay
        case pro

        var id: String { rawValue }

        var identifier: String {
            switch self {
            case .relay: return "relay"
            case .pro: return "pro"
            }
        }

        /// Two products per tier at the same level of one subscription group, so moving between periods is an upgrade or downgrade, not a second subscription.
        func productID(for period: BillingPeriod) -> String {
            "\(StoreManager.productIDStem).\(identifier).\(period.identifier)"
        }

        /// The highest tier present (`allCases` is cheapest first), so two entitlements meter as the dearer. Matched on the tier inside the identifier, because a table of whole ids dropped yearly subscribers to free.
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

        var plan: RelayPlan {
            switch self {
            case .relay: return .relay
            case .pro: return .pro
            }
        }

        var name: String {
            switch self {
            case .relay: return String(localized: "Relay")
            case .pro: return String(localized: "Pro")
            }
        }

        var tagline: String {
            switch self {
            case .relay: return String(localized: "Unlimited relay, on every Mac you own.")
            case .pro: return String(localized: "No limit on relay, and the whole toolbox.")
            }
        }

        /// One answer for all three paid tiers; free pairs a single Mac. Enforced client-side at the pairings by ``PlanCapability/extraMacs``.
        static let macCount = String(localized: "Every Mac")

        /// Whole lists, not "everything below plus": a card read alone looked like it offered less.
        var features: [String] {
            let relay = [
                String(localized: "Unlimited relay every day"),
                String(localized: "Every Mac you own, instead of one"),
                String(localized: "Sound from the Mac, and Picture in Picture"),
                String(localized: "Files that move both ways"),
                String(localized: "The clipboard history"),
                String(localized: "Told when a terminal needs you"),
            ]
            switch self {
            case .relay:
                return relay
            case .pro:
                return relay + [
                    String(localized: "Several shells at once, as tabs"),
                    String(localized: "Virtual displays, the Mac's own and any you add"),
                    String(localized: "Several Macs open at the same time"),
                    String(localized: "Macros, snippets and quick commands"),
                    String(localized: "Several of the Mac's windows in one picture"),
                    String(localized: "The sharpest picture over the relay"),
                ]
            }
        }

        var isRecommended: Bool { self == .pro }
    }

    func product(for tier: Tier, period: BillingPeriod) -> Product? {
        products.first { $0.id == tier.productID(for: period) }
    }

    func priceLabel(for tier: Tier, period: BillingPeriod) -> String? {
        guard let product = product(for: tier, period: period) else { return nil }
        return "\(product.displayPrice) / \(period.name)"
    }

    /// Shorter only: a longer button label wraps on a small phone.
    func compactPriceLabel(for tier: Tier, period: BillingPeriod) -> String? {
        guard let product = product(for: tier, period: period) else { return nil }
        return "\(product.displayPrice)/\(period.shortName)"
    }

    /// The yearly price divided by twelve in the store's currency. Rounded by the currency formatter, since `Decimal` division does not give the number a person would write.
    func effectiveMonthlyPrice(for tier: Tier) -> String? {
        guard let yearly = product(for: tier, period: .yearly) else { return nil }
        return (yearly.price / 12).formatted(yearly.priceFormatStyle)
    }

    /// The smallest yearly saving across tiers, for the one place a single number stands for both. Nil until a tier has both periods.
    var smallestYearlySaving: Int? {
        Tier.allCases.compactMap { yearlySaving(for: $0) }.min()
    }

    /// Computed from the two fetched prices, nil unless both exist, rounded down so the promise stays true.
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
        // Cleared first so a retry returns to the spinner.
        productsUnavailable = false
        do {
            let loaded = try await Product.products(for: Array(Self.paidProductIDs))
            // Tier order, then monthly first: the store answers by price, which reorders cards when a price changes.
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

    /// Collects the entitlement and its receipt together: the JWS belongs to one transaction, so it must be the winning tier's. `verification` is checked here for what the device unlocks; the relay checks again.
    private func refreshEntitlement() async {
        /// The signed transaction each live entitlement came with, by the tier it buys.
        var live: [Tier: String] = [:]
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            // Read off the identifier's middle word: two ids per tier, and a table of one would leave a yearly subscriber looking like they bought nothing.
            guard let tier = Tier.named(by: transaction.productID) else { continue }
            guard transaction.revocationDate == nil else { continue }
            // Off the VerificationResult, not the wrapped transaction: the JWS is Apple's signature over this checked result.
            live[tier] = result.jwsRepresentation
            await transaction.finish()
        }

        // The best tier, not the first: more than one can be live and the relay must hear the dearest.
        activeTier = Tier.allCases.last { live[$0] != nil }
        activeJWS = activeTier.flatMap { live[$0] }
        // Set only here. The loop runs to its end even when nothing is live, since "bought nothing" is an answer that must unlock the gates. See ``PlanAccess``.
        hasReadEntitlement = true
    }

    /// Writes no UI state: called from `Transaction.updates` too, and a background renewal error would sit on `purchaseError` until the paywall opened.
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
        let lookup = SecItemCopyMatching(SecretStore.attributes(query), &item)
        if lookup == errSecSuccess,
           let data = item as? Data,
           let key = String(data: data, encoding: .utf8) {
            return key
        }
        if lookup != errSecItemNotFound {
            storeLog.error("the relay key could not be read from the keychain: OSStatus \(lookup, privacy: .public); the relay is being given a new one")
        }
        let key = UUID().uuidString
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: Data(key.utf8),
        ]
        let stored = SecItemAdd(SecretStore.attributes(attrs), nil)
        if stored != errSecSuccess {
            storeLog.error("the relay key could not be stored in the keychain: OSStatus \(stored, privacy: .public); the next launch will make another one")
        }
        return key
    }
}
