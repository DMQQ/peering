import Foundation
import Security
import StoreKit
import os

private let storeLog = Logger(subsystem: "pl.dmq.peering", category: "store")

@Observable
@MainActor
final class StoreManager {
    static let monthlyID = "pl.dmq.peering.relay.monthly"
    static let lifetimeID = "pl.dmq.peering.relay.lifetime"

    private(set) var products: [Product] = []
    private(set) var isPro = false
    var isPurchasing = false
    var purchaseError: String?

    init() {
        Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handleVerification(result)
            }
        }
    }

    /// The API key sent to the relay when the user has a Pro entitlement.
    ///
    /// A UUID minted once and stored in Keychain. The relay does not validate it yet —
    /// that requires a backend. Until then, paying users are gated client-side and the
    /// quota is set high enough in production that it does not matter.
    var apiKey: String? {
        guard isPro else { return nil }
        return persistedKey()
    }

    func start() async {
        await refreshEntitlement()
        await fetchProducts()
    }

    func purchase(_ product: Product) async {
        isPurchasing = true
        purchaseError = nil
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handleVerification(verification)
            case .pending, .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            storeLog.error("purchase failed: \(error, privacy: .public)")
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlement()
        } catch {
            purchaseError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Private

    private func fetchProducts() async {
        do {
            let loaded = try await Product.products(for: [Self.monthlyID, Self.lifetimeID])
            products = loaded.sorted { $0.price < $1.price }
        } catch {
            storeLog.error("product fetch failed: \(error, privacy: .public)")
        }
    }

    private func refreshEntitlement() async {
        var hasPro = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result else { continue }
            guard tx.productID == Self.monthlyID || tx.productID == Self.lifetimeID else { continue }
            guard tx.revocationDate == nil else { continue }
            hasPro = true
            await tx.finish()
        }
        isPro = hasPro
    }

    private func handleVerification(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let tx) = result else { return }
        await tx.finish()
        await refreshEntitlement()
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
