import MacCastKit
import SwiftUI

struct AgentLaunch: Codable, Identifiable, Equatable {
    var id = UUID()
    let agentID: String
    let date: Date
    let macName: String
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

    static func lastUsed(_ agent: TerminalAgent, in entries: [AgentLaunch]) -> Date? {
        entries.first { $0.agentID == agent.id }?.date
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
    func launchAgent(_ agent: TerminalAgent) {
        AgentHistory.record(agent, macName: hostName ?? String(localized: "the Mac"))
        // The same step typing the command does: these programs lay themselves out for eighty
        // columns, and only the smallest text size holds that many on a phone held upright.
        if TerminalProgram.prefersSmallText(agent.command) {
            UserDefaults.standard.set(TerminalMetrics.TextSize.tiny.rawValue, forKey: PreferenceKeys.terminalTextSize)
        }
        runInNewTerminal(agent.command)
    }
}

/// The agents and their history, drawn inside the Mac terminals panel.
struct AgentsList: View {
    @Environment(SessionModel.self) private var model
    var onLaunched: () -> Void = {}

    @State private var history = AgentHistory.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.availableAgents) { agent in
                row(agent)
            }
            if model.availableAgents.isEmpty {
                Text("No supported agents were found on this Mac. Install one and it will show up here.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.vertical, 8)
            }
            historySection
        }
        .padding(16)
        .onAppear { model.refreshAgents() }
    }

    private func row(_ agent: TerminalAgent) -> some View {
        HStack(spacing: 14) {
            Image(systemName: agent.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 44, height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(.white.opacity(0.18))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: agent.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                lastUsedLine(AgentHistory.lastUsed(agent, in: history))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                start(agent)
            } label: {
                Text("Start")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.3)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Start \(agent.name)"))
        }
        .padding(12)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.14))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-row-\(agent.id)")
    }

    @ViewBuilder
    private func lastUsedLine(_ date: Date?) -> some View {
        if let date {
            Text("Last used \(date.formatted(.relative(presentation: .named)))")
        } else {
            Text("Never used")
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History")
                    .font(DisplayFont.display(20))
                    .foregroundStyle(.white)
                Spacer()
                if !history.isEmpty {
                    Button("Clear history") {
                        AgentHistory.clear()
                        history = []
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.top, 18)

            if history.isEmpty {
                Text("Agents you start will show up here.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(history.prefix(20).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                        }
                        historyRow(entry)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.14))
                )
            }
        }
    }

    private func historyRow(_ entry: AgentLaunch) -> some View {
        let name = TerminalAgent.all.first { $0.id == entry.agentID }?.name ?? entry.agentID
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                Text(verbatim: entry.macName)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(entry.date.formatted(.relative(presentation: .named)))
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent-history-row")
    }

    private func start(_ agent: TerminalAgent) {
        model.launchAgent(agent)
        history = AgentHistory.load()
        onLaunched()
    }
}
