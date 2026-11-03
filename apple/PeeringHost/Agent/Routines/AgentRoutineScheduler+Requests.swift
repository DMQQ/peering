import Foundation
import PeeringKit
import RemoteCore

/// The phone's routine requests. Each is answered with the owner's whole list.
extension AgentRoutineScheduler {
    func handle(clientID: String, request: AgentRequest, sink: @escaping AgentSessionManager.Sink) {
        queue.async { [self] in
            switch request {
            case .listRoutines:
                break
            case .saveRoutine(let routine):
                if let failure = save(routine, clientID: clientID) { sink(.failed(sessionID: nil, message: failure)) }
            case .deleteRoutine(let id):
                entries.removeAll { $0.routine.id == id && $0.ownerClientID == clientID }
                save()
            case .runRoutineNow(let id):
                if let failure = runNow(id, clientID: clientID) { sink(.failed(sessionID: nil, message: failure)) }
            default:
                return
            }
            sink(.routines(routines(of: clientID, now: Date())))
        }
    }

    /// The phone's copy carries no run history: what the Mac recorded is kept.
    private func save(_ incoming: AgentRoutine, clientID: String) -> String? {
        guard AgentRoutineValidation.problem(with: incoming) == nil else {
            return String(localized: "That routine is missing something it needs to run.")
        }
        guard let agent = AgentCatalogue.entry(for: incoming.agentID) else {
            return String(localized: "This Mac no longer has that agent.")
        }
        // An adapter does nothing until started, so one is made only to ask which modes its CLI has.
        guard agent.make(URL(fileURLWithPath: incoming.directory), nil).permissionModes.contains(incoming.permissionMode) else {
            return String(localized: "This agent cannot run in that mode.")
        }
        var routine = incoming
        routine.nextRunAt = nil
        if let index = entries.firstIndex(where: { $0.routine.id == routine.id }) {
            guard entries[index].ownerClientID == clientID else { return String(localized: "That routine is no longer here.") }
            routine.lastRun = entries[index].routine.lastRun
            let rescheduled = routine.schedule != entries[index].routine.schedule || (routine.isEnabled && !entries[index].routine.isEnabled)
            entries[index].routine = routine
            if rescheduled { entries[index].scheduledFrom = Date() }
        } else {
            guard entries.filter({ $0.ownerClientID == clientID }).count < Self.routinesPerClient else {
                return String(localized: "This Mac already keeps as many routines as it can.")
            }
            routine.lastRun = nil
            entries.append(AgentRoutineEntry(ownerClientID: clientID, routine: routine, scheduledFrom: Date()))
        }
        save()
        return nil
    }

    private func runNow(_ id: UUID, clientID: String) -> String? {
        guard let index = entries.firstIndex(where: { $0.routine.id == id && $0.ownerClientID == clientID }) else {
            return String(localized: "That routine is no longer here.")
        }
        guard entries[index].routine.lastRun?.outcome != .running else {
            return String(localized: "This routine is already running.")
        }
        fire(at: index, now: Date())
        save()
        return nil
    }

    private func routines(of clientID: String, now: Date) -> [AgentRoutine] {
        entries.filter { $0.ownerClientID == clientID }.map { entry in
            var routine = entry.routine
            routine.nextRunAt = routine.isEnabled ? AgentRoutinePlan.nextFire(of: routine.schedule, after: entry.scheduledFrom) : nil
            return routine
        }
    }
}
