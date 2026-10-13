import StoreKit

/// What the paywall and the tour's last page sell. Both are Pro: one billed monthly, one paid once.
enum PlanOffer: Hashable {
    case subscription
    case lifetime
}

extension StoreManager {
    /// Nil until the store has answered, and for lifetime also once it is owned, so a screen offers nothing it cannot sell.
    func product(for offer: PlanOffer) -> Product? {
        switch offer {
        case .subscription: return product(for: .pro, period: .monthly)
        case .lifetime: return hasLifetime ? nil : lifetimeProduct
        }
    }

    /// Shorter only: a longer button label wraps on a small phone.
    func buttonTitle(for offer: PlanOffer) -> String? {
        guard let product = product(for: offer) else { return nil }
        switch offer {
        case .subscription: return String(localized: "Continue with Pro · \(product.displayPrice)/mo")
        case .lifetime: return String(localized: "Get Lifetime · \(product.displayPrice)")
        }
    }
}
