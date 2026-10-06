import MacCastKit
import SwiftUI

struct AgentLaunch: Codable, Identifiable, Equatable {
    var id = UUID()
    let agentID: String
    let date: Date
    let macName: String
    /// The shell this launch opened, once the Mac has said which it is.
    ///
    /// A history row is worth having only if it goes somewhere, and this is where: a launch whose
    /// shell is still running opens that shell, and one whose shell is gone starts the agent
    /// again. Nil for the entries written before the two ends kept this, and for a launch that
    /// never got a shell.
    var terminalID: UUID?
}

/// What has been started from this phone, per agent, so the hub can say when each was last used and
/// can list what came before. The rows it is drawn as live in ``TerminalHubScreen``.
enum AgentHistory {
    static let key = "Peering.agentHistory"
    static let limit = 50

    static func load() -> [AgentLaunch] {
        #if DEBUG
        seedIfRequested()
        #endif
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([AgentLaunch].self, from: data)
        else { return [] }
        return entries.sorted { $0.date > $1.date }
    }

    static func record(_ agent: TerminalAgent, macName: String, at date: Date = .now) {
        var entries = load()
        entries.insert(AgentLaunch(agentID: agent.id, date: date, macName: macName), at: 0)
        save(Array(entries.prefix(limit)))
    }

    static func clear() { save([]) }

    /// Starting an agent again from its own history row moves that row to the top rather than
    /// adding a second one, so the list stays one line per launch the user chose.
    static func restart(_ entry: AgentLaunch, macName: String, at date: Date = .now) {
        var entries = load().filter { $0.id != entry.id }
        entries.insert(AgentLaunch(id: entry.id, agentID: entry.agentID, date: date, macName: macName), at: 0)
        save(Array(entries.prefix(limit)))
    }

    static func lastUsed(_ agent: TerminalAgent, in entries: [AgentLaunch]) -> Date? {
        entries.first { $0.agentID == agent.id }?.date
    }

    /// Says which shell an agent's newest launch opened, once the Mac has answered with it.
    ///
    /// The newest, because that is the one the user means when they come back to the row: the
    /// launch that just happened. Older entries keep whatever they had.
    static func attach(terminalID: UUID, toNewest agentID: String) {
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.agentID == agentID }) else { return }
        entries[index].terminalID = terminalID
        save(entries)
    }

    private static func save(_ entries: [AgentLaunch]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    #if DEBUG
    private static func seedIfRequested() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "Peering.seedAgentHistory"),
              defaults.data(forKey: key) == nil else { return }
        let day: TimeInterval = 86_400
        let hour: TimeInterval = 3_600
        let mac = "Damian's MacBook Pro"
        let seed: [(String, TimeInterval)] = [
            ("claude", 2 * hour), ("codex", day), ("opencode", 3 * day),
            ("claude", 4 * day), ("hermes", 7 * day), ("codex", 9 * day),
        ]
        save(seed.map { AgentLaunch(agentID: $0.0, date: .now - $0.1, macName: mac) })
    }
    #endif
}

extension SessionModel {
    func launchAgent(_ agent: TerminalAgent, restarting entry: AgentLaunch? = nil) {
        let macName = hostName ?? String(localized: "the Mac")
        if let entry {
            AgentHistory.restart(entry, macName: macName)
        } else {
            AgentHistory.record(agent, macName: macName)
        }
        // The same step typing the command does: these programs lay themselves out for eighty
        // columns, and only the smallest text size holds that many on a phone held upright.
        if TerminalProgram.prefersSmallText(agent.command) {
            UserDefaults.standard.set(TerminalMetrics.TextSize.tiny.rawValue, forKey: PreferenceKeys.terminalTextSize)
        }
        runInNewTerminal(agent.command)
    }
}
