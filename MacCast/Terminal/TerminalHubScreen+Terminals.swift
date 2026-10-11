import MacCastKit
import RemoteCore
import SwiftUI

extension TerminalHubScreen {
    /// A shell an agent was launched in belongs to the Agents page, where it shows in History while it runs: listing it here too made one agent appear in both tabs.
    private var shellCards: [TerminalCardDigest] {
        let agentShells = Set(AgentHistory.load().compactMap(\.terminalID))
        return model.terminalCards.filter { !agentShells.contains($0.id) }
    }

    var terminalsSection: some View {
        let shells = shellCards
        return VStack(alignment: .leading, spacing: 12) {
            if shells.isEmpty {
                TerminalEmptyState(canCreate: model.canOpenAnotherShellFromCards) {
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
            TerminalWindowCard(terminal: terminal, index: index, host: model.hostName)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename", systemImage: "character.cursor.ibeam") { beginRename(terminal) }
                .menuInk()
            Button("End", systemImage: "xmark", role: .destructive) { pendingEnd = .terminal(terminal.id) }
                .menuDanger()
        } preview: {
            TerminalWindowCard(terminal: terminal, index: 0, host: model.hostName)
                .frame(width: 340)
                .background(ColorPalette.backdrop)
        }
        .accessibilityIdentifier("terminal-row")
    }
}
