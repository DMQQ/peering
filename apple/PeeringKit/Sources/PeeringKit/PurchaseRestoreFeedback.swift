/// Completing with nothing found must not look like an ignored tap.
public enum PurchaseRestoreFeedback {
    public static func message(didRestore: Bool, error: String?) -> String? {
        guard !didRestore else { return nil }
        return error ?? String(localized: "No purchases to restore on this Apple Account.")
    }
}
