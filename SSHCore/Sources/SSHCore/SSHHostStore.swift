import Foundation
import os

private let hostStoreLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// The saved hosts, as one JSON blob in `UserDefaults`.
///
/// The same shape the app already uses for its custom macros and its terminal history, and for the
/// same reason: a short list of small records that is read once and written whole. It is also the
/// reason nothing secret is in here — a `UserDefaults` value is readable by anything that can
/// attach to the container, which is fine for a list of servers and not fine for a password.
///
/// `defaults` is injectable so a test does not have to write into the real app's preferences and
/// then clean up after itself — which is the kind of test that passes alone and fails in a suite.
public struct SSHHostStore: Sendable {
    public static let key = "Peering.sshHosts"

    // `UserDefaults` is not `Sendable` — it is a mutable reference type — but it is
    // documented as thread-safe, and the alternative is dropping `Sendable` from a store whose
    // only job is to hand a value to a main-actor model and take one back.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [SSHHost] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        do {
            return try JSONDecoder().decode([SSHHost].self, from: data)
        } catch {
            // Logged, and returned as empty rather than as a crash. This is the difference between
            // a list that looks lost and an app that will not open — and the blob is still on disk
            // either way, so nothing is actually gone.
            hostStoreLog.error("could not read saved SSH hosts: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    public func save(_ hosts: [SSHHost]) {
        do {
            defaults.set(try JSONEncoder().encode(hosts), forKey: Self.key)
        } catch {
            hostStoreLog.error("could not save SSH hosts: \(String(describing: error), privacy: .public)")
        }
    }

    /// The list in the order the list shows it: most recently connected first, and anything never
    /// connected in the order it was added.
    ///
    /// Sorting on read rather than on write, so `lastConnectedAt` moving does not have to be
    /// accompanied by a reorder of the stored array — the array's order stays what the user made
    /// it, and the screen's order is a view of that.
    public static func ordered(_ hosts: [SSHHost]) -> [SSHHost] {
        hosts.sorted { left, right in
            switch (left.lastConnectedAt, right.lastConnectedAt) {
            case let (l?, r?): return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return left.createdAt < right.createdAt
            }
        }
    }
}
