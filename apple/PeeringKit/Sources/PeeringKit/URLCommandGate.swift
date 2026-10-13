import Foundation

/// The state behind ``URLCommandPolicy``: a command held for the app lock, and one waiting for a person's answer.
///
/// Locking drops a pending confirmation, so an alert left on screen cannot be accepted behind the lock.
public struct URLCommandGate: Equatable, Sendable {
    /// Starts locked until the root view says otherwise, so a link that launches the app cannot beat the lock.
    public private(set) var isLocked = true
    public private(set) var confirming: URLCommand?
    private var held: URLCommand?

    public init() {}

    /// - Returns: the command to run now, if any.
    public mutating func submit(_ command: URLCommand, hasLiveSession: Bool, hasLiveShells: Bool) -> URLCommand? {
        switch URLCommandPolicy.decide(command, isLocked: isLocked, hasLiveSession: hasLiveSession, hasLiveShells: hasLiveShells) {
        case .run: return command
        case .confirm: confirming = command
        case .holdUntilUnlock: held = command
        }
        return nil
    }

    /// - Returns: a command held while locked, to be submitted again now that the lock is open.
    public mutating func setLocked(_ locked: Bool) -> URLCommand? {
        isLocked = locked
        if locked {
            confirming = nil
            return nil
        }
        defer { held = nil }
        return held
    }

    /// - Returns: the confirmed command, or nil when none is waiting or the lock came up meanwhile.
    public mutating func confirm() -> URLCommand? {
        defer { confirming = nil }
        return isLocked ? nil : confirming
    }

    public mutating func cancelConfirmation() {
        confirming = nil
    }
}
