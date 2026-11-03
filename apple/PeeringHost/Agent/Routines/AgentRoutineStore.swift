import Foundation
import RemoteCore

/// One routine as the Mac keeps it: whose it is, and when its schedule was last satisfied.
struct AgentRoutineEntry: Codable, Equatable, Sendable {
    let ownerClientID: String
    var routine: AgentRoutine
    /// When the routine was saved or last ran: the next time is counted from here.
    var scheduledFrom: Date
}

/// Every routine on this Mac, in one JSON file under Application Support.
struct AgentRoutineStore: Sendable {
    let file: URL

    static func standard() -> AgentRoutineStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "pl.dmq.peering.host"
        return AgentRoutineStore(file: support.appendingPathComponent(bundle).appendingPathComponent("AgentRoutines.json"))
    }

    /// An absent file is no routines; an unreadable one is an error, so it is not overwritten with nothing.
    func load() throws -> [AgentRoutineEntry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([AgentRoutineEntry].self, from: Data(contentsOf: file))
    }

    func save(_ entries: [AgentRoutineEntry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: file, options: [.atomic])
    }
}
