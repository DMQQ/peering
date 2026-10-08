import Foundation
import os

private let historyLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// The name and address are copied in rather than looked up from ``SSHHost``, so the log still names a server the user has since deleted.
public struct SSHConnectionRecord: Identifiable, Codable, Sendable, Hashable {
    /// `Codable` here is not forward-compatible, which is acceptable for a log: the store answers a failure by starting a new one.
    public enum Outcome: Codable, Sendable, Hashable {
        case connected
        case failed(String)

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        public var reason: String? {
            if case .failed(let reason) = self { return reason }
            return nil
        }
    }

    public let id: UUID
    public let hostID: UUID
    public let name: String
    public let detail: String
    public let startedAt: Date
    public let endedAt: Date
    public let outcome: Outcome

    public init(
        id: UUID = UUID(),
        hostID: UUID,
        name: String,
        detail: String,
        startedAt: Date,
        endedAt: Date,
        outcome: Outcome
    ) {
        self.id = id
        self.hostID = hostID
        self.name = name
        self.detail = detail
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
    }

    public var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }
}

/// The connection log, saved whole as a JSON blob in `UserDefaults`; newest first, and ``limit`` is the length on screen as well as on disk.
public struct SSHConnectionHistoryStore: Sendable {
    public static let key = "Peering.sshConnectionHistory"
    public static let limit = 20

    // `UserDefaults` is not `Sendable` but is documented thread-safe.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [SSHConnectionRecord] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        do {
            let decoded = try JSONDecoder().decode([SSHConnectionRecord].self, from: data)
            let kept = Array(decoded.prefix(Self.limit))
            if kept.count != decoded.count { save(kept) }
            return kept
        } catch {
            historyLog.error("could not read the SSH connection log: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    public func save(_ records: [SSHConnectionRecord]) {
        do {
            defaults.set(try JSONEncoder().encode(Array(records.prefix(Self.limit))), forKey: Self.key)
        } catch {
            historyLog.error("could not save the SSH connection log: \(String(describing: error), privacy: .public)")
        }
    }
}
