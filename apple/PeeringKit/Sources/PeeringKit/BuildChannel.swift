import Foundation

/// Whether this build is the owner's own, so their devices can be filtered out of the numbers.
public enum BuildChannel {
    /// TestFlight installs carry a receipt named `sandboxReceipt`; the App Store's is `receipt`.
    public static func isInternal(isDebug: Bool, receiptFileName: String?) -> Bool {
        isDebug || receiptFileName == "sandboxReceipt"
    }
}
