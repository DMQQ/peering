import Foundation
import PeeringKit
import RemoteCore
import Testing

struct AgentRoutineValidationTests {
    private func routine(
        name: String = "Nightly tests",
        directory: String = "/Users/someone/project",
        prompt: String = "Run the tests and fix what fails.",
        schedule: AgentRoutineSchedule = .daily(hour: 2, minute: 0, weekdays: [1, 2, 3, 4, 5, 6, 7]),
        stopAfterMinutes: Int? = nil
    ) -> AgentRoutine {
        AgentRoutine(
            name: name, agentID: "claude", directory: directory, prompt: prompt,
            schedule: schedule, permissionMode: .plan, stopAfterMinutes: stopAfterMinutes
        )
    }

    @Test func aCompleteRoutineHasNoProblem() {
        #expect(AgentRoutineValidation.problem(with: routine()) == nil)
    }

    @Test func aBlankNameIsRefused() {
        #expect(AgentRoutineValidation.problem(with: routine(name: "  ")) == .missingName)
    }

    @Test func aBlankPromptIsRefused() {
        #expect(AgentRoutineValidation.problem(with: routine(prompt: "\n")) == .missingPrompt)
    }

    @Test func aRelativeFolderIsRefused() {
        #expect(AgentRoutineValidation.problem(with: routine(directory: "project")) == .relativeFolder)
    }

    @Test func anIntervalUnderFifteenMinutesIsRefused() {
        #expect(AgentRoutineValidation.problem(with: routine(schedule: .every(minutes: 5))) == .intervalOutOfRange)
        #expect(AgentRoutineValidation.problem(with: routine(schedule: .every(minutes: 15))) == nil)
    }

    @Test func aTimeOutsideTheDayIsRefused() {
        #expect(AgentRoutineValidation.problem(with: routine(schedule: .daily(hour: 24, minute: 0, weekdays: [2]))) == .timeOutOfRange)
    }

    @Test func aDailyRoutineNeedsAValidWeekday() {
        #expect(AgentRoutineValidation.problem(with: routine(schedule: .daily(hour: 9, minute: 0, weekdays: []))) == .noWeekdays)
        #expect(AgentRoutineValidation.problem(with: routine(schedule: .daily(hour: 9, minute: 0, weekdays: [0]))) == .noWeekdays)
    }

    @Test func aTimeLimitMustBePositive() {
        #expect(AgentRoutineValidation.problem(with: routine(stopAfterMinutes: 0)) == .stopAfterOutOfRange)
        #expect(AgentRoutineValidation.problem(with: routine(stopAfterMinutes: 30)) == nil)
    }

    @Test func theDefaultModeIsPlanWhereTheAgentHasIt() {
        #expect(AgentRoutineValidation.defaultMode(among: [.manual, .acceptEdits, .plan, .auto]) == .plan)
        #expect(AgentRoutineValidation.defaultMode(among: [.manual, .acceptEdits, .auto]) == .acceptEdits)
        #expect(AgentRoutineValidation.defaultMode(among: [.auto]) == .manual)
    }
}
