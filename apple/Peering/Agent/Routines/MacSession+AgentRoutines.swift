import Foundation
import PeeringKit
import RemoteCore

extension MacSession {
    func sendRoutineRequest(_ request: AgentRequest) {
        agentRoutinesAwaiting = true
        agentRoutineFailure = nil
        wire?.sendAgent(request)
    }
}

extension SessionModel {
    var agentRoutines: [AgentRoutine]? { activeSession?.agentRoutines }

    var agentRoutineFailure: String? { activeSession?.agentRoutineFailure }

    /// The chat agents this Mac offers, in the order the hub shows them.
    var routineAgents: [TerminalAgent] {
        TerminalAgent.all.filter { $0.supportsChat && activeSession?.hostChatAgents.contains($0.id) == true }
    }

    /// The modes a chat with this agent listed, or every mode when none is open to ask; the Mac refuses one its CLI lacks.
    func routineModes(for agentID: String) -> [AgentPermissionMode] {
        let known = activeSession?.agentSessions.first { $0.agentID == agentID && !$0.permissionModes.isEmpty }?.permissionModes
        return known ?? AgentPermissionMode.allCases
    }

    func refreshAgentRoutines() { activeSession?.sendRoutineRequest(.listRoutines) }

    func saveAgentRoutine(_ routine: AgentRoutine) { activeSession?.sendRoutineRequest(.saveRoutine(routine)) }

    func deleteAgentRoutine(_ id: UUID) { activeSession?.sendRoutineRequest(.deleteRoutine(id: id)) }

    func runAgentRoutineNow(_ id: UUID) { activeSession?.sendRoutineRequest(.runRoutineNow(id: id)) }
}
