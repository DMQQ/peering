import Foundation
import RemoteCore
import Testing

@testable import PeeringKit

@Suite("Live Activity push content")
struct LiveActivityPushBuilderTests {
    private let started = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_500)

    private func truth(_ chats: [LiveActivityChat] = []) -> LiveActivityTruth {
        LiveActivityTruth(phase: .active, startedAt: started, path: .relay, chats: chats)
    }

    private func command(_ kind: LiveActivityKind, event: LiveActivityCommand.Event = .update, chats: [LiveActivityChat] = [], alert: LiveActivityCommand.Alert? = nil) -> LiveActivityCommand {
        LiveActivityCommand(
            kind: kind, event: event, token: "aa", environment: .sandbox,
            truth: truth(chats), priority: alert == nil ? nil : 10, alert: alert
        )
    }

    private func encoded(_ message: RelayActivityPush) throws -> Data {
        try RelayMessageCodec.encode(message.contentState)
    }

    @Test("a date in the pushed state is the seconds since 2001, which a default decoder reads back")
    func dateIsReferenceSeconds() throws {
        let push = try LiveActivityPushBuilder.push(for: command(.session), hostID: "mac-1", now: now)
        let data = try encoded(push)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["startedAt"] as? Double == 800_000_000)
        let decoded = try JSONDecoder().decode(SessionActivityState.self, from: data)
        #expect(decoded.startedAt == started)
    }

    @Test("the dismissal the planner chose reaches the relay message")
    func dismissalIsCarried() throws {
        var ending = command(.agentChat, event: .end)
        ending.dismissalSeconds = 1800
        #expect(try LiveActivityPushBuilder.push(for: ending, hostID: "mac-1", now: now).dismissalSeconds == 1800)
        #expect(try LiveActivityPushBuilder.push(for: command(.agentChat, event: .end), hostID: "mac-1", now: now).dismissalSeconds == nil)
    }

    @Test("a session push has the coded fields and no free text")
    func sessionState() throws {
        let chats = [LiveActivityChat(id: "c1", symbol: "sparkles", state: .needsYou)]
        let push = try LiveActivityPushBuilder.push(for: command(.session, chats: chats), hostID: "mac-1", now: now)
        let decoded = try JSONDecoder().decode(SessionActivityState.self, from: try encoded(push))
        #expect(decoded.phase == .active)
        #expect(decoded.path == .relay)
        #expect(decoded.hostName == nil)
        #expect(decoded.hostKey == HostKey.of("mac-1"))
        #expect(decoded.work?.map(\.name) == [""])
        #expect(decoded.work?.first?.state == .waiting)
        let text = String(decoding: try encoded(push), as: UTF8.self)
        #expect(!text.contains("mac-1"))
    }

    @Test("the pushed session state, sorted, is exactly these keys")
    func sessionJSON() throws {
        let push = try LiveActivityPushBuilder.push(for: command(.session), hostID: "mac-1", now: now)
        let text = String(decoding: try encoded(push), as: UTF8.self)
        #expect(text == "{\"hostKey\":\"\(HostKey.of("mac-1"))\",\"path\":\"Relay\",\"phase\":\"active\",\"startedAt\":800000000}")
    }

    @Test("an agent chat push carries ids and states, with title and folder empty and the Mac only by key")
    func agentChatState() throws {
        let chats = [LiveActivityChat(id: "c1", symbol: "sparkles", state: .working), LiveActivityChat(id: "c2", symbol: "sparkles", state: .needsYou)]
        let push = try LiveActivityPushBuilder.push(for: command(.agentChat, chats: chats), hostID: "mac-1", now: now)
        let decoded = try JSONDecoder().decode(AgentChatActivityState.self, from: try encoded(push))
        #expect(decoded.chat.id == "c2")
        #expect(decoded.chat.state == .needsYou)
        #expect(decoded.chat.title.isEmpty)
        #expect(decoded.chat.folder.isEmpty)
        #expect(decoded.chat.hostID == nil)
        #expect(decoded.chat.updatedAt == now)
        #expect(decoded.waiting == 1)
        #expect(decoded.working == 1)
        #expect(decoded.hostKey == HostKey.of("mac-1"))
    }

    @Test("a start carries the type name, attributes and alert the relay requires")
    func startPush() throws {
        let chats = [LiveActivityChat(id: "c1", symbol: "sparkles", state: .needsYou)]
        let push = try LiveActivityPushBuilder.push(for: command(.agentChat, event: .start, chats: chats, alert: .needsApproval), hostID: "mac-1", now: now)
        #expect(push.event == .start)
        #expect(push.attributesType == "AgentChatActivityAttributes")
        #expect(push.attributes == .object(["origin": .string("host")]))
        #expect(push.alertTitle?.isEmpty == false)
        #expect(push.alertBody?.isEmpty == false)
        #expect(push.priority == 10)
        #expect(push.environment == .sandbox)
    }

    @Test("an update carries no attributes")
    func updatePush() throws {
        let push = try LiveActivityPushBuilder.push(for: command(.session), hostID: "mac-1", now: now)
        #expect(push.attributesType == nil)
        #expect(push.attributes == nil)
        #expect(push.alertTitle == nil)
        #expect(push.contentStateFits)
    }

    @Test("a state from an earlier build, without the new keys, still decodes")
    func earlierBuildsDecode() throws {
        let session = #"{"phase":"active","hostName":"Studio","startedAt":800000000}"#
        let decoded = try JSONDecoder().decode(SessionActivityState.self, from: Data(session.utf8))
        #expect(decoded.hostKey == nil)
        #expect(decoded.hostName == "Studio")
    }

    @Test("the host key is short, stable, and not the id")
    func hostKey() {
        let key = HostKey.of("0F3C9A52-AAAA-BBBB-CCCC-123456789ABC")
        #expect(key.count == 12)
        #expect(key == HostKey.of("0F3C9A52-AAAA-BBBB-CCCC-123456789ABC"))
        #expect(key != HostKey.of("another"))
    }
}
