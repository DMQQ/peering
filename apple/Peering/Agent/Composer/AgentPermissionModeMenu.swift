import PeeringKit
import RemoteCore
import SwiftUI

/// How freely this chat's agent may act, switchable from the chat's own bar.
///
/// Lists only the modes the agent's CLI can really be put in, so the same control reads
/// differently per agent: Claude Code can ask, while Codex and OpenCode cannot ask at all and
/// choose between staying in the folder and having no limit.
struct AgentPermissionModeMenu: View {
    @Environment(SessionModel.self) private var model
    let session: RemoteAgentSession

    var body: some View {
        let current = session.permissionMode ?? session.permissionModes.first ?? .manual
        Menu {
            ForEach(session.permissionModes, id: \.self) { mode in
                Button {
                    model.setAgentPermissionMode(mode, in: session.id)
                } label: {
                    Text(Self.title(mode))
                    Text(Self.detail(mode, agentID: session.agentID))
                    Image(systemName: mode == current ? "checkmark" : Self.symbol(mode))
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: Self.symbol(current))
                    .font(.system(size: 12, weight: .semibold))
                Text(Self.title(current))
                    .font(.system(size: 14))
                    .lineLimit(1)
            }
        }
        .accessibilityLabel(Text("Permissions, \(Self.title(current))"))
    }

    static func title(_ mode: AgentPermissionMode) -> String {
        switch mode {
        case .manual: String(localized: "Manual")
        case .acceptEdits: String(localized: "Auto accept")
        case .plan: String(localized: "Plan")
        case .auto: String(localized: "Auto")
        }
    }

    static func symbol(_ mode: AgentPermissionMode) -> String {
        switch mode {
        case .manual: "hand.raised"
        case .acceptEdits: "checkmark.shield"
        case .plan: "list.bullet.clipboard"
        case .auto: "bolt.shield"
        }
    }

    static func detail(_ mode: AgentPermissionMode, agentID: String) -> String {
        switch (mode, agentID) {
        case (.manual, _):
            String(localized: "Asks before it edits or runs anything")
        case (.acceptEdits, "claude"):
            String(localized: "Edits go through, commands still ask")
        case (.acceptEdits, _):
            String(localized: "Works freely inside the folder, nothing outside it")
        case (.plan, _):
            String(localized: "Looks and plans first, changes nothing until you approve")
        case (.auto, "claude"):
            String(localized: "A reviewer model checks each action before it runs")
        case (.auto, _):
            String(localized: "Never asks, and can reach outside the folder")
        }
    }
}
