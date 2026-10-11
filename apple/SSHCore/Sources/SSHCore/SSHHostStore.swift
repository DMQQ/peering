import Foundation
import os

private let hostStoreLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// The saved hosts as one JSON blob in `UserDefaults`; nothing secret is in here, since a `UserDefaults` value is readable by anything that can attach to the container. `defaults` is injectable so tests do not write into real preferences.
public struct SSHHostStore: Sendable {
    public static let key = "Peering.sshHosts"

    // `UserDefaults` is not `Sendable` but is documented thread-safe.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [SSHHost] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        do {
            return try JSONDecoder().decode([SSHHost].self, from: data)
        } catch {
            // Logged and returned empty rather than crashing; the blob is still on disk, so nothing is gone.
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

    /// Most recently connected first, then never-connected in the order added. Sorted on read so the stored array keeps the order the user made.
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
