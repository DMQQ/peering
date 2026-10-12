import Foundation
import MacCastKit
import RemoteCore
import Security
import StoreKit
import os

private let storeLog = Logger(subsystem: "pl.dmq.peering", category: "store")

// RelayPlan lives in MacCastKit so its allowance can be tested; this file is about buying.

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

    /// A non-consumable, bought once and never renewed. Pro only: a lifetime of unlimited relay is priced as the whole plan, not as the cheapest one. The relay repeats this identifier in `Relay/src/storekit.rs`.
    nonisolated static let lifetimeProductID = "\(productIDStem).pro.lifetime1"

    nonisolated static let paidProductIDs: Set<String> = Set(
        Tier.allCases.flatMap { tier in
            BillingPeriod.allCases.map { tier.productID(for: $0) }
        }
    ).union([lifetimeProductID])

    private(set) var products: [Product] = []
    /// Kept out of ``products``, which is the subscription ladder the period picker and cards walk.
    private(set) var lifetimeProduct: Product?
    /// True once a lifetime purchase is live, so a screen can say so instead of offering it again.
    private(set) var hasLifetime = false
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
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handleVerification(result)
            }
        }
    }

    // `nonisolated(unsafe)` so `deinit` can cancel it; written once in `init`.
    @ObservationIgnored private nonisolated(unsafe) var updatesTask: Task<Void, Never>?

    deinit {
        updatesTask?.cancel()
    }

    /// A UUID kept in the Keychain. Not a credential: it grants nothing unless it is on the relay's server-side paid list (PEERINGD_PAID_KEYS), which nothing here can add it to.
    var apiKey: String? {
        guard isPro else { return nil }
        return persistedKey()
    }

    func start() async {
        await refreshEntitlement()
        // Not awaited: with no network the retries take half a minute, and the caller has more to set up.
        Task { await fetchProducts() }
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
        let analyticsProduct = Self.analyticsName(for: product.id)
        Analytics.purchaseStarted(product: analyticsProduct)
        let outcome = await performPurchase(product)
        Analytics.purchaseFinished(outcome: "\(outcome)", product: analyticsProduct)
        return outcome
    }

    /// A closed set for the event: the store's identifiers are not sent.
    nonisolated static func analyticsName(for productID: String) -> String {
        if productID == lifetimeProductID { return "pro_lifetime" }
        guard Tier.named(by: productID) == .pro else { return "other" }
        return productID.hasSuffix(BillingPeriod.yearly.identifier) ? "pro_yearly" : "pro_monthly"
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
            Analytics.failed(error, in: .purchase)
            Analytics.purchaseFailed(error, product: Self.analyticsName(for: product.id))
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
            Analytics.failed(error, in: .purchase)
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

        /// What the paywall offers. Relay is no longer sold; it stays a case so a subscription bought before still reads as a paid plan.
        static let sold: [Tier] = [.pro]

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
            case .pro: return String(localized: "Unlimited time away from your own network.")
            }
        }

        var features: [String] {
            [
                String(localized: "Unlimited time away from your own network, relayed or direct"),
                String(localized: "The sharpest picture over the relay"),
            ]
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

    // MARK: - Private

    private func fetchProducts() async {
        // Cleared first so a retry returns to the spinner.
        productsUnavailable = false
        let backoff = RetryBackoff()
        var retry = 0
        while true {
            if await loadProducts() { return }
            guard let delay = backoff.delay(beforeRetry: retry), !Task.isCancelled else { break }
            retry += 1
            try? await Task.sleep(for: delay)
        }
        productsUnavailable = true
    }

    /// `false` when the store could not be reached, so the caller may try again. An empty answer is the store's answer and is not retried.
    private func loadProducts() async -> Bool {
        do {
            let loaded = try await Product.products(for: Array(Self.paidProductIDs))
            // Tier order, then monthly first: the store answers by price, which reorders cards when a price changes.
            products = Tier.allCases.flatMap { tier in
                BillingPeriod.allCases.compactMap { period in
                    loaded.first { $0.id == tier.productID(for: period) }
                }
            }
            lifetimeProduct = loaded.first { $0.id == Self.lifetimeProductID }
            // An empty answer is not a slow one. The store has spoken.
            productsUnavailable = products.isEmpty
            return true
        } catch {
            Analytics.failed(error, in: .purchase)
            storeLog.error("product fetch failed: \(error, privacy: .public)")
            return false
        }
    }

    /// Collects the entitlement and its receipt together: the JWS belongs to one transaction, so it must be the winning tier's. `verification` is checked here for what the device unlocks; the relay checks again.
    private func refreshEntitlement() async {
        /// The signed transaction each live entitlement came with, by the tier it buys.
        var live: [Tier: String] = [:]
        var lifetimeLive = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            // Read off the identifier's middle word: two ids per tier, and a table of one would leave a yearly subscriber looking like they bought nothing.
            guard let tier = Tier.named(by: transaction.productID) else { continue }
            guard transaction.revocationDate == nil else { continue }
            // Off the VerificationResult, not the wrapped transaction: the JWS is Apple's signature over this checked result.
            // A lifetime receipt wins over a subscription's for the same tier: it is the one that never lapses under a running session.
            let isLifetime = transaction.productID == Self.lifetimeProductID
            if isLifetime { lifetimeLive = true }
            if isLifetime || live[tier] == nil {
                live[tier] = result.jwsRepresentation
            }
            await transaction.finish()
        }
        hasLifetime = lifetimeLive

        // The best tier, not the first: more than one can be live and the relay must hear the dearest.
        activeTier = Tier.allCases.last { live[$0] != nil }
        activeJWS = activeTier.flatMap { live[$0] }
        // Set only here. The loop runs to its end even when nothing is live, since "bought nothing" is an answer that must stop the app waiting. See ``PlanAccess``.
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
        case .unverified(let transaction, let error):
            Analytics.receiptVerificationFailed(error, product: Self.analyticsName(for: transaction.productID))
            storeLog.error("transaction not verified: \(error, privacy: .public)")
            return false
        }
    }

    // MARK: - Keychain key

    private static let keychainService = "pl.dmq.peering"
    private static let keychainAccount = "relayApiKey"

    /// `nil` when the Keychain cannot be read: minting a key then would be a different key on every call, none of them on the paid list.
    private func persistedKey() -> String? {
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
            storeLog.error("the relay key could not be read from the keychain: OSStatus \(lookup, privacy: .public)")
            return nil
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
