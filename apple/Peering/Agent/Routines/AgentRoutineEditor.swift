import PeeringKit
import RemoteCore
import SwiftUI

/// Makes or changes one routine. Nothing reaches the Mac until Save.
struct AgentRoutineEditor: View {
    @Environment(SessionModel.self) var model
    @Binding var draft: AgentRoutineDraft
    let isNew: Bool
    let chooseFolder: () -> Void
    let close: () -> Void

    @State private var confirmsDelete = false
    @State private var pendingAutoMode = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                whatCard
                AgentRoutineScheduleCard(draft: $draft)
                permissionsCard
                if let problem = draft.problem {
                    Text(verbatim: AgentRoutineText.problem(problem))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !isNew { deleteButton }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(ColorPalette.backdrop)
        .navigationTitle(isNew ? Text("New routine") : Text(verbatim: draft.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save")) {
                    model.saveAgentRoutine(draft.routine)
                    close()
                }
                .disabled(draft.problem != nil)
            }
        }
        .confirmationDialog(String(localized: "Delete this routine?"), isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button(String(localized: "Delete routine"), role: .destructive) {
                model.deleteAgentRoutine(draft.id)
                close()
            }
        } message: {
            Text("Chats it already ran stay in your chat list.")
        }
        .alert(String(localized: "Let the agent act without asking?"), isPresented: $pendingAutoMode) {
            Button(String(localized: "Allow everything"), role: .destructive) { draft.permissionMode = .auto }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("With nobody watching, the agent can change or delete any file and run any command in that folder. Plan or Auto accept is safer for a routine.")
        }
    }

    private var whatCard: some View {
        Controls.card(String(localized: "Routine")) {
            TextField(String(localized: "Name"), text: $draft.name)
                .textInputAutocapitalization(.sentences)
            Controls.divider
            Controls.picker(String(localized: "Agent"), systemImage: "sparkles", selection: agentBinding) {
                ForEach(model.routineAgents) { agent in Text(verbatim: agent.name).tag(agent.id) }
            }
            Controls.divider
            Button(action: chooseFolder) {
                Controls.row(String(localized: "Folder"), systemImage: "folder") {
                    Text(verbatim: draft.directory.map(AgentFolderPath.name(of:)) ?? String(localized: "Choose"))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Controls.divider
            TextField(String(localized: "What should the agent do?"), text: $draft.prompt, axis: .vertical)
                .lineLimit(3...10)
        }
    }

    private var agentBinding: Binding<String> {
        Binding(get: { draft.agentID }, set: { agentID in
            draft.agentID = agentID
            let modes = model.routineModes(for: agentID)
            if !modes.contains(draft.permissionMode) { draft.permissionMode = AgentRoutineValidation.defaultMode(among: modes) }
        })
    }

    private var permissionsCard: some View {
        Controls.card(
            String(localized: "While it runs"),
            footer: AgentPermissionModeMenu.detail(draft.permissionMode, agentID: draft.agentID)
        ) {
            Controls.picker(String(localized: "Permissions"), systemImage: AgentPermissionModeMenu.symbol(draft.permissionMode), selection: modeBinding) {
                ForEach(model.routineModes(for: draft.agentID), id: \.self) { mode in
                    Text(verbatim: AgentPermissionModeMenu.title(mode)).tag(mode)
                }
            }
            Controls.divider
            Controls.picker(String(localized: "Stop after"), systemImage: "timer", selection: $draft.stopAfterMinutes) {
                Text("No limit").tag(Int?.none)
                ForEach([15, 30, 60, 120, 240], id: \.self) { minutes in
                    Text(verbatim: Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                        .tag(Int?.some(minutes))
                }
            }
            Controls.divider
            Controls.toggle(String(localized: "On"), systemImage: "power", isOn: $draft.isEnabled)
        }
    }

    /// Auto is set only after the warning is accepted.
    private var modeBinding: Binding<AgentPermissionMode> {
        Binding(get: { draft.permissionMode }, set: { mode in
            if mode == .auto { pendingAutoMode = true } else { draft.permissionMode = mode }
        })
    }

    private var deleteButton: some View {
        Button(role: .destructive) { confirmsDelete = true } label: {
            Text("Delete routine")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ColorPalette.danger)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .overlay(Capsule().strokeBorder(ColorPalette.danger.opacity(0.4)))
        }
        .buttonStyle(.plain)
    }
}
