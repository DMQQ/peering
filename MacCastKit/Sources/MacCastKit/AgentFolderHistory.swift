import Foundation

/// The folders chats were last started in, per agent, newest first.
public enum AgentFolderHistory {
    public static let key = "Peering.agentFolders"
    public static let limit = 20

    public struct Entry: Codable, Equatable, Sendable {
        public let agentID: String
        public let path: String
        public let macName: String
        public let date: Date

        public init(agentID: String, path: String, macName: String, date: Date) {
            self.agentID = agentID
            self.path = path
            self.macName = macName
            self.date = date
        }
    }

    public static func load(from defaults: UserDefaults = .standard) -> [Entry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries.sorted { $0.date > $1.date }
    }

    /// The folders new terminals were started in, which the terminals tab lists as its history.
    public static let terminalAgentID = "terminal"

    public static func clear(agentID: String, in defaults: UserDefaults = .standard) {
        let kept = load(from: defaults).filter { $0.agentID != agentID }
        if let data = try? JSONEncoder().encode(kept) {
            defaults.set(data, forKey: key)
        }
    }

    /// The home folder is what starting with nothing means, so recording no choice as a recent would add a row that says nothing.
    public static func record(
        directory: String?,
        agentID: String,
        macName: String?,
        at date: Date = .now,
        in defaults: UserDefaults = .standard
    ) {
        guard let directory else { return }
        var entries = load(from: defaults).filter { !($0.agentID == agentID && $0.path == directory) }
        entries.insert(Entry(agentID: agentID, path: directory, macName: macName ?? "", date: date), at: 0)
        if let data = try? JSONEncoder().encode(Array(entries.prefix(limit))) {
            defaults.set(data, forKey: key)
        }
    }
}

public enum AgentFolderPath {
    public static func parent(of path: String?) -> String? {
        guard let path, path.count > 1 else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    public static func name(of path: String) -> String {
        path == "/" ? "/" : (path as NSString).lastPathComponent
    }

    /// The path as a person reads it: the Mac's home folder written as `~`, so a deep folder does not open with the user's account name.
    public static func display(_ path: String, home: String?) -> String {
        guard let home, !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
