import Testing

@testable import PeeringKit

struct AgentApprovalBodyTests {
    @Test func theCommandComesBeforeTheReason() {
        #expect(AgentApprovalBody.text(command: "rm -rf build", reason: "Contains a glob") == "rm -rf build\n\nContains a glob")
    }

    @Test func aReasonAloneIsStillShown() {
        #expect(AgentApprovalBody.text(command: nil, reason: "Needs approval") == "Needs approval")
    }

    @Test func aCommandAloneIsShown() {
        #expect(AgentApprovalBody.text(command: "ls", reason: "  ") == "ls")
    }

    @Test func nothingToSayIsNil() {
        #expect(AgentApprovalBody.text(command: "", reason: nil) == nil)
    }
}
