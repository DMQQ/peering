import Testing

@testable import PeeringKit

@Suite struct AgentStreamResumeTests {
    @Test func codexResumesTheThreadItWasGiven() {
        #expect(AgentCodexStream(directory: "/tmp", cliSessionID: "thread-1").cliSessionID == "thread-1")
        #expect(AgentCodexStream(directory: "/tmp").cliSessionID == nil)
    }

    @Test func openCodeResumesTheSessionItWasGiven() {
        #expect(AgentOpenCodeStream(directory: "/tmp", cliSessionID: "ses_1").cliSessionID == "ses_1")
    }
}
