import MacCastKit
import SwiftUI

struct AgentLaunch: Codable, Identifiable, Equatable {
    var id = UUID()
    let agentID: String
    let date: Date
    let macName: String
    var terminalID: UUID?
}

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

    static func restart(_ entry: AgentLaunch, macName: String, at date: Date = .now) {
        var entries = load().filter { $0.id != entry.id }
        entries.insert(AgentLaunch(id: entry.id, agentID: entry.agentID, date: date, macName: macName), at: 0)
        save(Array(entries.prefix(limit)))
    }

    static func lastUsed(_ agent: TerminalAgent, in entries: [AgentLaunch]) -> Date? {
        entries.first { $0.agentID == agent.id }?.date
    }

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
        // Same step as typing the command: these programs lay out for 80 columns, and only the smallest text size fits that on an upright phone.
        if TerminalProgram.prefersSmallText(agent.command) {
            UserDefaults.standard.set(TerminalMetrics.TextSize.tiny.rawValue, forKey: PreferenceKeys.terminalTextSize)
        }
        runInNewTerminal(agent.command)
    }
}
