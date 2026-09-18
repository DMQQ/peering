import Foundation

/// What a saved server asks for before it will connect.
///
/// A property of the *server* rather than one switch for the tab, because the machines in this list
/// are not equally sensitive — a Raspberry Pi on the desk and a production box are two different
/// things, and a single setting covering both ends up turned off, because the Pi does not need it.
///
/// Deliberately not a field on ``SSHCredential``. A credential is a secret this app *presents* to
/// the server; this is a question the app asks the *user*. They are stored apart for that reason,
/// and the passcode is in ``SSHPasscodeStore`` rather than in the same blob.
public enum SSHHostLock: String, Codable, Sendable, Hashable, CaseIterable {
    /// Nothing. The connection opens on the tap, which is what every server did before this existed.
    ///
    /// `off` rather than `none`, and that is not a style preference: `SSHHostLock?` already has a
    /// `.none`, so `someHost.lock == .none` written against an *optional* resolves to `Optional`'s
    /// case and silently compares against nil instead of against this one. It compiles, it is
    /// wrong, and it is wrong in the direction that reads as "not locked". A name that cannot be
    /// confused with the other one costs nothing here.
    case off
    /// A six-digit passcode this app holds, typed on a pad before the session opens.
    case passcode
    /// The device's owner authentication: Face ID, Touch ID, or the device passcode behind them.
    case biometrics

    public var isLocked: Bool { self != .off }

    /// Decoded by hand so an unrecognised case degrades to `none` rather than throwing.
    ///
    /// A throw here would take the whole host list down with it: ``SSHHostStore/load()`` decodes the
    /// array in one go and answers an empty list when that fails, so one string this build does not
    /// know would show the user a Servers tab that has lost every machine they ever saved.
    ///
    /// Degrading is the lesser harm. An unrecognised value can only have been written by a build
    /// that knows more than this one, and a build that cannot evaluate a lock cannot honour it
    /// either — refusing to open the list would not make the connection more protected, it would
    /// only make the app look broken. A *recognised* lock is still enforced in full.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SSHHostLock(rawValue: raw) ?? .off
    }
}
