import Foundation
import os

/// Where the pin store says it could not be read, for an owner that wants to count it. RemoteCore has no analytics, so the app installs the handler.
///
/// A raise before a handler exists is kept and delivered when one is installed: the store is read at launch, possibly before the app has wired its analytics.
public final class PinStoreAlarm: Sendable {
    public static let shared = PinStoreAlarm()

    private struct State {
        var handler: (@Sendable (Int32?) -> Void)?
        var waiting: [Int32?] = []
    }

    private static let waitingLimit = 4
    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    public static func install(_ onUnreadable: @escaping @Sendable (Int32?) -> Void) {
        shared.install(onUnreadable)
    }

    /// `status` is the keychain's `OSStatus`, or `nil` when the stored bytes would not decode.
    static func raise(status: Int32?) { shared.raise(status: status) }

    func install(_ onUnreadable: @escaping @Sendable (Int32?) -> Void) {
        let waiting = state.withLock { state -> [Int32?] in
            state.handler = onUnreadable
            defer { state.waiting = [] }
            return state.waiting
        }
        for status in waiting { onUnreadable(status) }
    }

    func raise(status: Int32?) {
        let handler = state.withLock { state -> (@Sendable (Int32?) -> Void)? in
            if state.handler == nil, state.waiting.count < Self.waitingLimit { state.waiting.append(status) }
            return state.handler
        }
        handler?(status)
    }
}
