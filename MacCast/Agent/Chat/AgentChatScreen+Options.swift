import MacCastKit
import RemoteCore
import SwiftUI

extension AgentChatScreen {
    func offersModelPicker(_ session: RemoteAgentSession) -> Bool {
        AgentModelName.offersPicker(agentID: session.agentID, hostSupportsPicker: model.hostSupportsAgentModelPicker)
    }

    func shortModel(_ session: RemoteAgentSession) -> String {
        session.model.map(AgentModelName.short) ?? String(localized: "Default")
    }

    /// What was four header buttons, down by the composer where the thumb is: this chat's model and permissions as chips that say their current value, and the rest behind a menu.
    func optionsBar(_ session: RemoteAgentSession) -> some View {
        HStack(spacing: 8) {
            if offersModelPicker(session) {
                Menu {
                    Button("Default") { model.setAgentModel(nil, in: session.id) }
                    ForEach(AgentModelName.suggestions(agentID: session.agentID, hostChoices: session.modelChoices), id: \.self) { name in
                        Button {
                            model.setAgentModel(name, in: session.id)
                        } label: {
                            if AgentModelName.isCurrent(name, current: session.model) {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(name)
                            }
                        }
                    }
                    Divider()
                    Button("Custom…") {
                        modelText = session.model ?? ""
                        typingModelFor = session.id
                    }
                } label: {
                    optionChip(shortModel(session), symbol: "cpu")
                }
                .accessibilityLabel(Text("Model, \(shortModel(session))"))
            }
            if model.hostSupportsAgentPermissionModes, session.permissionModes.count > 1 {
                let current = session.permissionMode ?? session.permissionModes.first ?? .manual
                Menu {
                    ForEach(session.permissionModes, id: \.self) { mode in
                        Button {
                            model.setAgentPermissionMode(mode, in: session.id)
                        } label: {
                            Text(AgentPermissionModeMenu.title(mode))
                            Text(AgentPermissionModeMenu.detail(mode, agentID: session.agentID))
                            Image(systemName: mode == current ? "checkmark" : AgentPermissionModeMenu.symbol(mode))
                        }
                    }
                } label: {
                    optionChip(AgentPermissionModeMenu.title(current), symbol: AgentPermissionModeMenu.symbol(current))
                }
                .accessibilityLabel(Text("Permissions, \(AgentPermissionModeMenu.title(current))"))
            }
            Spacer(minLength: 0)
            Menu {
                if model.hostSupportsAgentUsage {
                    Button { showsUsage = true } label: {
                        Label("Usage and limits", systemImage: "gauge.with.dots.needle.33percent")
                    }
                }
                Button("Rename", systemImage: "character.cursor.ibeam") { beginRename(session) }
                Divider()
                Button(role: .destructive) { pendingClose = session } label: {
                    Label("Close chat", systemImage: "xmark")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 34, height: 30)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
                    .contentShape(Capsule())
            }
            .accessibilityLabel(Text("Chat options"))
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    func optionChip(_ title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(verbatim: title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 11)
        .frame(height: 30)
        .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
        .contentShape(Capsule())
    }
}
