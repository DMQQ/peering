import Foundation
import os

/// Where the pin store says it could not be read, for an owner that wants to count it. RemoteCore has no analytics, so the app installs the handler.
public enum PinStoreAlarm {
    private static let handler = OSAllocatedUnfairLock<(@Sendable (Int32?) -> Void)?>(initialState: nil)

    public static func install(_ onUnreadable: @escaping @Sendable (Int32?) -> Void) {
        handler.withLock { $0 = onUnreadable }
    }

    /// `status` is the keychain's `OSStatus`, or `nil` when the stored bytes would not decode.
    static func raise(status: Int32?) {
        let current = handler.withLock { $0 }
        current?(status)
    }
}
