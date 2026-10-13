import PeeringKit
import RemoteCore
import SwiftUI

extension AgentChatScreen {
    var tabStrip: some View {
        TabStrip(items: model.agentSessions, selection: currentID) { session, isSelected in
            chip(session, isSelected: isSelected)
        } accessory: {
            EmptyView()
        }
    }

    func chip(_ session: RemoteAgentSession, isSelected: Bool) -> some View {
        TabChip(
            isSelected: isSelected,
            onSelect: { withAnimation(Motion.tap) { currentID = session.id } },
            onClose: { pendingClose = session },
            closeLabel: String(localized: "Close \(session.title)")
        ) {
            mark(for: session.state)
        } name: {
            TabName(text: session.title, isSelected: isSelected, colour: .white)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename(session) })
        .contextMenu {
            Button("Rename", systemImage: "character.cursor.ibeam") { beginRename(session) }
                .menuInk()
            Button("Close", systemImage: "xmark", role: .destructive) { pendingClose = session }
                .menuDanger()
        }
    }

    func beginRename(_ session: RemoteAgentSession) {
        renameText = session.title
        renamingID = session.id
    }

    @ViewBuilder
    func mark(for state: AgentSessionState) -> some View {
        switch state {
        case .working:
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .symbolEffect(.variableColor.iterative.reversing)
        case .awaitingApproval:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ColorPalette.caution)
                .symbolEffect(.pulse)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ColorPalette.danger)
        case .idle, .exited:
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}
