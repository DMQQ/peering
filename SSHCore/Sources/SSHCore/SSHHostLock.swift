import Foundation

/// A property of the server rather than one switch for the tab, since the machines are not equally sensitive. Not a field on ``SSHCredential``: a credential is a secret the app presents, this is a question it asks the user.
public enum SSHHostLock: String, Codable, Sendable, Hashable, CaseIterable {
    /// Nothing. `off` rather than `none`: against `SSHHostLock?`, `lock == .none` resolves to `Optional.none` and silently compares against nil.
    case off
    case passcode
    case biometrics

    public var isLocked: Bool { self != .off }

    /// Decoded by hand so an unrecognised case degrades to `off` rather than throwing: a throw would make ``SSHHostStore/load()`` return an empty list and lose every saved server. A recognised lock is still enforced in full.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SSHHostLock(rawValue: raw) ?? .off
    }
}
