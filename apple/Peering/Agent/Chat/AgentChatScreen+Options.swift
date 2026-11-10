import PeeringKit
import RemoteCore
import SwiftUI

extension AgentChatScreen {
    func offersModelPicker(_ session: RemoteAgentSession) -> Bool {
        AgentModelName.offersPicker(agentID: session.agentID)
    }

    func shortModel(_ session: RemoteAgentSession) -> String {
        session.model.map(AgentModelName.short) ?? String(localized: "Default")
    }

    /// The one row over the composer: what to do next, this chat's model and permissions as chips that say their current value, and the context meter at the end. It scrolls sideways before it wraps, so the composer keeps the screen; the rest is behind the header's menu.
    func chipRow(_ session: RemoteAgentSession, followUps: [AgentFollowUps.Suggestion], watch: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    AgentFollowUpBar(suggestions: followUps, choose: { follow(up: $0, in: session) }, watchOnMac: watch)
                    optionChips(session)
                }
            }
            .scrollClipDisabled()
            if let usage = session.usage, AgentContextBar.hasContent(usage) {
                AgentContextBar(usage: usage) { showsUsage = true }
            }
        }
        // Clear of the tray's corner curves, which the chips' own rounder ends would otherwise crowd.
        .padding(.horizontal, Self.trayInset)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func optionChips(_ session: RemoteAgentSession) -> some View {
        Group {
            if offersModelPicker(session) {
                Menu {
                    Button("Default") { model.setAgentModel(nil, in: session.id) }
                    ForEach(AgentModelName.suggestions(agentID: session.agentID, hostChoices: session.modelChoices), id: \.self) { name in
                        Button {
                            model.setAgentModel(name, in: session.id)
                        } label: {
                            if AgentModelName.isCurrent(name, current: session.model) {
                                Label(AgentModelName.short(name), systemImage: "checkmark")
                            } else {
                                Text(AgentModelName.short(name))
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
                .accessibilityIdentifier("chat.modelMenu")
            }
            if session.permissionModes.count > 1 {
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
        }
    }

    /// In the navigation bar's trailing corner, where a screen's own actions live.
    func moreMenu(_ session: RemoteAgentSession) -> some View {
        Menu {
            Button { showsUsage = true } label: {
                Label("Usage and limits", systemImage: "gauge.with.dots.needle.33percent")
            }
            Button { showsSpendingCap = true } label: {
                Label("Spending cap", systemImage: "gauge.with.dots.needle.100percent")
            }
            Button { showsChanges = true } label: {
                Label("Changes", systemImage: "doc.badge.gearshape")
            }
            Button { showsPreview = true } label: {
                Label("Web preview", systemImage: "safari")
            }
            Button("Rename", systemImage: "character.cursor.ibeam") { beginRename(session) }
            Divider()
            Button(role: .destructive) { pendingClose = session } label: {
                Label("Close chat", systemImage: "xmark")
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Chat options"))
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
        .frame(height: ChatChips.height)
        .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
        .contentShape(Capsule())
    }
}

enum ChatChips {
    static let height: CGFloat = 30
}
