import PeeringKit
import RemoteCore
import SwiftUI

extension TerminalHubScreen {
    /// A shell an agent was launched in belongs to the Agents page, where it shows in History while it runs: listing it here too made one agent appear in both tabs.
    var shellCards: [TerminalCardDigest] {
        let agentShells = Set(AgentHistory.load().compactMap(\.terminalID))
        return model.terminalCards.filter { !agentShells.contains($0.id) }
    }

    var terminalsSection: some View {
        let shells = shellCards
        return VStack(alignment: .leading, spacing: 12) {
            if shells.isEmpty {
                TerminalEmptyState {
                    path.append(.terminalFolder(nil))
                }
            } else {
                ForEach(Array(shells.enumerated()), id: \.element.id) { index, terminal in
                    terminalRow(terminal, index: index)
                }
            }
        }
        .padding(.top, 20)
    }

    private func terminalRow(_ terminal: TerminalCardDigest, index: Int) -> some View {
        Button {
            model.selectTerminal(terminal.id)
            path.append(.terminal(terminal.id))
        } label: {
            TerminalWindowCard(terminal: terminal, index: index, host: model.shownHostName)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename", systemImage: "character.cursor.ibeam") { beginRename(terminal) }
                .menuInk()
            Button("End", systemImage: "xmark", role: .destructive) { pendingEnd = .terminal(terminal.id) }
                .menuDanger()
        } preview: {
            TerminalPeek(terminal: terminal)
        }
        .accessibilityIdentifier("terminal-row")
    }
}
