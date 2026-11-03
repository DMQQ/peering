import Foundation
import PeeringKit
import RemoteCore
import Testing

struct AgentRoutineDraftTests {
    @Test func aNewDraftNeedsAFolderBeforeItCanBeSaved() {
        var draft = AgentRoutineDraft(agentID: "claude", modes: [.manual, .acceptEdits, .plan, .auto])
        draft.name = "Morning review"
        draft.prompt = "Summarise yesterday's commits."
        #expect(draft.problem == .relativeFolder)
        draft.directory = "/Users/someone/project"
        #expect(draft.problem == nil)
    }

    @Test func aNewDraftStartsInPlanMode() {
        let draft = AgentRoutineDraft(agentID: "claude", modes: [.manual, .acceptEdits, .plan, .auto])
        #expect(draft.permissionMode == .plan)
    }

    @Test func hoursBecomeMinutesOnTheWire() {
        var draft = AgentRoutineDraft(agentID: "claude", modes: [.plan])
        draft.cadence = .interval
        draft.intervalValue = 3
        draft.intervalUnit = .hours
        #expect(draft.schedule == .every(minutes: 180))
    }

    @Test func aRoutineReadsBackIntoTheSameFields() {
        let routine = AgentRoutine(
            name: "Every two hours", agentID: "codex", directory: "/tmp/project", prompt: "Check CI.",
            schedule: .every(minutes: 120), permissionMode: .acceptEdits, stopAfterMinutes: 20
        )
        let draft = AgentRoutineDraft(routine)
        #expect(draft.intervalUnit == .hours)
        #expect(draft.intervalValue == 2)
        #expect(draft.permissionMode == .acceptEdits)
        #expect(draft.routine == routine)
    }

    @Test func weekdaysGoOutInOrder() {
        var draft = AgentRoutineDraft(agentID: "claude", modes: [.plan])
        draft.weekdays = [6, 2, 4]
        #expect(draft.schedule == .daily(hour: 9, minute: 0, weekdays: [2, 4, 6]))
    }
}
