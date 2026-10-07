import Foundation
import RemoteCore
import Testing

@testable import MacCastKit

@Suite struct AgentPlanModeTests {
    @Test func eachModeHasTheNameTheCLIExpects() {
        #expect(AgentPermissionMode.plan.claudeCLIName == "plan")
        #expect(AgentPermissionMode.acceptEdits.claudeCLIName == "acceptEdits")
        #expect(AgentPermissionMode.manual.claudeCLIName == "default")
    }

    @Test func theProposedPlanIsTheCardsBody() {
        let call = AgentClaudeStream.call(id: "t", name: "ExitPlanMode", input: ["plan": "1. Read\n2. Edit"])
        #expect(call.title == "Plan")
        #expect(call.detail == "1. Read\n2. Edit")
    }

    @Test func planModeSurvivesTheWire() throws {
        let data = try JSONEncoder().encode([AgentPermissionMode.plan])
        #expect(try JSONDecoder().decode([AgentPermissionMode].self, from: data) == [.plan])
    }
}
