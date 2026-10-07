import Foundation
import Testing

@testable import RemoteCore

@Suite struct AgentBrowseWaitingTests {
    @Test func theWaitingNoticeSurvivesTheWire() throws {
        let event = AgentEvent.browseWaiting(path: "/Users/me/Desktop", message: "Allow it on the Mac.")
        let data = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(AgentEvent.self, from: data) == event)
    }
}
