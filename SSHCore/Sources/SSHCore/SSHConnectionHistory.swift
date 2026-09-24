import Foundation
import os

private let historyLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// One connection that has finished, and how it went.
///
/// The name and the address are *copied* in rather than looked up from ``SSHHost`` when the row is
/// drawn, which looks like duplication and is the point: a log that can only name a server the user
/// still has is a log that goes blank the moment they delete one, and "deleted the server" is
/// exactly the moment somebody wants to know when they last connected to it. It is also the reason
/// a row can be drawn for a server that no longer exists at all.
public struct SSHConnectionRecord: Identifiable, Codable, Sendable, Hashable {
    /// How the connection ended.
    ///
    /// `Codable` here is not forward-compatible — a record written by a build that knows a case
    /// this one does not is a record this one cannot read — which is the same trade
    /// ``SSHCredential`` records and is acceptable for the same reason: this is a log, and the
    /// store answers a failure by starting a new one.
    public enum Outcome: Codable, Sendable, Hashable {
        /// The shell opened and then ended, whether the user closed it or the server hung up.
        case connected
        /// It never opened. The sentence is the same one the shell's own error line shows.
        case failed(String)

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        /// The reason, when there is one to show.
        public var reason: String? {
            if case .failed(let reason) = self { return reason }
            return nil
        }
    }

    public let id: UUID
    /// The server this was, so a row can offer to open it again.
    public let hostID: UUID
    /// What the server was called at the time, and what it was addressed as.
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

    /// How long the shell was up, which for a failure is how long it took to fail.
    public var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }
}

/// The connection log, saved whole — the same JSON-blob-in-`UserDefaults` shape as the host list.
///
/// The newest record is at the front, and the array is what gets drawn, so ``limit`` is the length
/// of the list on screen as well as on disk. Twenty matches the remote-session history and is small
/// enough that the blob stays a thing `UserDefaults` is the right home for.
public struct SSHConnectionHistoryStore: Sendable {
    public static let key = "Peering.sshConnectionHistory"
    public static let limit = 20

    // `UserDefaults` is not `Sendable` — it is a mutable reference type — but it is
    // documented as thread-safe, and the alternative is dropping `Sendable` from a store whose
    // only job is to hand a value to a main-actor model and take one back.
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
