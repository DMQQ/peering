import Foundation
import Testing
@testable import RemoteCore

struct AgentRoutineWireTests {
    @Test func aHelloFromBeforeRoutinesReadsAsNoSupport() throws {
        let old = #"{"serverID":"s","hostName":"Mac","protocolVersion":20,"alreadyPaired":true}"#
        let hello = try JSONDecoder().decode(ServerHello.self, from: Data(old.utf8))
        #expect(hello.supportsAgentRoutines == nil)
    }

    @Test func aSaveRequestSurvivesAnEncodeAndDecode() throws {
        let routine = AgentRoutine(
            name: "Nightly", agentID: "claude", directory: "/tmp/project", prompt: "Run the tests.",
            schedule: .daily(hour: 2, minute: 30, weekdays: [2, 3]), permissionMode: .plan, stopAfterMinutes: 30
        )
        let decoded = try JSONDecoder().decode(AgentRequest.self, from: JSONEncoder().encode(AgentRequest.saveRoutine(routine)))
        #expect(decoded == .saveRoutine(routine))
    }

    @Test func aListOfRoutinesCarriesTheLastRun() throws {
        let run = AgentRoutineRun(startedAt: Date(timeIntervalSince1970: 1_800_000_000), outcome: .skipped, detail: "Not installed")
        let routine = AgentRoutine(
            name: "Hourly", agentID: "codex", directory: "/tmp", prompt: "Check CI.",

    @Test func aRoutineSavedBeforeTheNotifyFieldDecodesAsUnset() throws {
        let routine = AgentRoutine(
            name: "Old", agentID: "claude", directory: "/tmp", prompt: "Go.",
            schedule: .every(minutes: 60), permissionMode: .plan
        )
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(routine)) as? [String: Any])
        object.removeValue(forKey: "notifiesWhenDone")
        let decoded = try JSONDecoder().decode(AgentRoutine.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.notifiesWhenDone == nil)
    }
            schedule: .every(minutes: 60), permissionMode: .acceptEdits, lastRun: run
        )
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: JSONEncoder().encode(AgentEvent.routines([routine])))
        #expect(decoded == .routines([routine]))
    }
}
