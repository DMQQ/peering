/// The sentence shown after Restore Purchases finishes.
///
/// StoreKit has three observable answers: an entitlement came back, it failed with a reason, or
/// it completed successfully but found nothing. The last two must not look like an ignored tap.
public enum PurchaseRestoreFeedback {
    public static func message(didRestore: Bool, error: String?) -> String? {
        guard !didRestore else { return nil }
        return error ?? String(localized: "No purchases to restore on this Apple Account.")
    }
}
