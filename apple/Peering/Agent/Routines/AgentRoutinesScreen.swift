import PeeringKit
import RemoteCore
import SwiftUI

enum AgentRoutineRoute: Hashable {
    case editor
    case folder(String?)
}

/// Every routine on the Mac, each with its last run, and the editor and folder pages it opens.
struct AgentRoutinesScreen: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path: [AgentRoutineRoute] = []
    @State private var draft: AgentRoutineDraft?

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationTitle(Text("Routines"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Done")) { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { startNew() } label: { Image(systemName: "plus") }
                            .accessibilityLabel(Text("New routine"))
                            .disabled(model.routineAgents.isEmpty)
                    }
                }
                .navigationDestination(for: AgentRoutineRoute.self, destination: page)
        }
        .preferredColorScheme(.dark)
        .onAppear { model.refreshAgentRoutines() }
    }

    @ViewBuilder
    private func page(_ route: AgentRoutineRoute) -> some View {
        switch route {
        case .editor:
            if let binding = Binding($draft) {
                AgentRoutineEditor(draft: binding, isNew: !isSaved(binding.wrappedValue.id), chooseFolder: {
                    path.append(.folder(binding.wrappedValue.directory))
                }, close: { path = [] })
            }
        case .folder(let directory):
            AgentFolderPicker(
                title: String(localized: "Folder"),
                agentID: draft?.agentID ?? "",
                directory: directory,
                open: { path.append(.folder($0)) }
            ) { chosen in
                draft?.directory = chosen ?? model.activeSession?.agentPicker.startPath
                path = [.editor]
            }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let failure = model.agentRoutineFailure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(ColorPalette.danger)
                }
                if let routines = model.agentRoutines {
                    if routines.isEmpty { empty }
                    ForEach(routines) { routine in
                        AgentRoutineRow(routine: routine) { edit(routine) }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(16)
        }
        .background(ColorPalette.backdrop)
        .refreshable { model.refreshAgentRoutines() }
    }

    private var empty: some View {
        Text("A routine sends a prompt to an agent on your Mac at the times you choose, in a chat of its own. Approvals it needs reach this phone as notifications.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
    }

    private func isSaved(_ id: UUID) -> Bool {
        model.agentRoutines?.contains { $0.id == id } == true
    }

    private func startNew() {
        guard let agent = model.routineAgents.first else { return }
        draft = AgentRoutineDraft(agentID: agent.id, modes: model.routineModes(for: agent.id))
        path = [.editor]
    }

    private func edit(_ routine: AgentRoutine) {
        draft = AgentRoutineDraft(routine)
        path = [.editor]
    }
}
