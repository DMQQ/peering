import Foundation
import RemoteCore

/// What the Mac keeps on disk for a chat, so it survives the host restarting.
public struct AgentSessionRecord: Codable, Equatable, Sendable {
    public var id: UUID
    public var ownerClientID: String
    public var agentID: String
    public var title: String
    public var directory: String
    public var createdAt: Date
    /// The id the CLI resumes with. Nil when the CLI never said one, and then the chat can be read but not continued.
    public var cliSessionID: String?
    public var model: String?
    public var permissionMode: AgentPermissionMode
    public var usage: AgentUsage?
    public var events: [AgentStreamEvent]
    public var nextIndex: UInt64
    public var truncatedAtFront: Bool

    public init(
        id: UUID,
        ownerClientID: String,
        agentID: String,
        title: String,
        directory: String,
        createdAt: Date,
        cliSessionID: String?,
        model: String?,
        permissionMode: AgentPermissionMode,
        usage: AgentUsage?,
        events: [AgentStreamEvent],
        nextIndex: UInt64,
        truncatedAtFront: Bool
    ) {
        self.id = id
        self.ownerClientID = ownerClientID
        self.agentID = agentID
        self.title = title
        self.directory = directory
        self.createdAt = createdAt
        self.cliSessionID = cliSessionID
        self.model = model
        self.permissionMode = permissionMode
        self.usage = usage
        self.events = events
        self.nextIndex = nextIndex
        self.truncatedAtFront = truncatedAtFront
    }
}

/// One JSON file per chat, written whole and atomically so a crash mid-write leaves the previous copy.
public struct AgentSessionDiskStore: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func save(_ record: AgentSessionRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = file(for: record.id)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// A file this build cannot read (written by a newer one, or damaged) is skipped, not deleted.
    public func loadAll() -> [AgentSessionRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(name).path) else { return nil }
            return try? decoder.decode(AgentSessionRecord.self, from: data)
        }
    }

    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(for: id))
    }

    private func file(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
