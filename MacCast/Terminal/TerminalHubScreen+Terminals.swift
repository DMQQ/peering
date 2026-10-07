import MacCastKit
import RemoteCore
import SwiftUI

extension TerminalHubScreen {
    var terminalsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.terminalCards.isEmpty {
                TerminalEmptyState(canCreate: model.canOpenAnotherShellFromCards) {
                    path.append(.terminalFolder(nil))
                }
            } else {
                ForEach(Array(model.terminalCards.enumerated()), id: \.element.id) { index, terminal in
                    terminalRow(terminal, index: index)
                }
                newTerminalRow
            }
        }
    }

    private var newTerminalRow: some View {
        PlanLocked(
            capability: .shellTabs,
            title: String(localized: "New terminal"),
            diameter: 30,
            isIncluded: model.canOpenAnotherShellFromCards
        ) {
            Button { path.append(.terminalFolder(nil)) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                    Text("New terminal").font(.system(size: 14.5, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New terminal")
        }
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
        }
        .accessibilityIdentifier("terminal-row")
    }
}
