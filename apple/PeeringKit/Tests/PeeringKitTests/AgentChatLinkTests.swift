import Foundation
import RemoteCore
import Testing

@testable import PeeringKit

@Suite("Agent chat link")
struct AgentChatLinkTests {
    private func snapshot(id: String, hostID: String?, state: AgentChatSnapshot.State = .finished) -> AgentChatSnapshot {
        AgentChatSnapshot(
            id: id, hostID: hostID, title: "", symbol: "sparkles", folder: "", state: state, activity: nil,
            planDone: 0, planTotal: 0, planStepNumber: nil, planStep: nil, updatedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    @Test("a finished chat's link parses back to the chat and the Mac")
    func roundTrip() throws {
        let id = UUID()
        let url = snapshot(id: id.uuidString, hostID: "mac-1").url
        let parsed = try #require(AgentChatSnapshot.parse(url))
        #expect(parsed.chatID == id)
        #expect(parsed.hostID == "mac-1")
    }

    @Test("a link without a Mac still names the chat")
    func noHost() throws {
        let id = UUID()
        let parsed = try #require(AgentChatSnapshot.parse(snapshot(id: id.uuidString, hostID: nil).url))
        #expect(parsed.chatID == id)
        #expect(parsed.hostID == nil)
    }

    @Test("a link that is not a chat, or names no valid chat, opens nothing")
    func rejected() {
        #expect(AgentChatSnapshot.parse(URL(string: "peering://connect?id=x")!) == nil)
        #expect(AgentChatSnapshot.parse(URL(string: "peering://chat?id=not-a-uuid")!) == nil)
        #expect(AgentChatSnapshot.parse(URL(string: "peering://chat")!) == nil)
        #expect(AgentChatSnapshot.parse(URL(string: "https://chat?id=\(UUID().uuidString)")!) == nil)
    }
}
