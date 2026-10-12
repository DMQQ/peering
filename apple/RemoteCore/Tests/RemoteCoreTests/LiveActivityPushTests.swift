import Foundation
import Testing

@testable import RemoteCore

@Suite("Live Activity push wire")
struct LiveActivityPushTests {
    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test("the kind byte is 0x24")
    func kindByte() {
        #expect(MessageKind.activityToken.rawValue == 0x24)
    }

    @Test("the token message writes null for a missing token")
    func payloadJSON() throws {
        let payload = ActivityTokenPayload(activity: .session, pushToken: "0a1b", pushToStartToken: nil, environment: .sandbox)
        #expect(try json(payload) == #"{"activity":"session","environment":"sandbox","pushToStartToken":null,"pushToken":"0a1b"}"#)
    }

    @Test("an ended activity sends both tokens null")
    func endedJSON() throws {
        let payload = ActivityTokenPayload(activity: .agentChat, pushToken: nil, pushToStartToken: nil, environment: .production)
        #expect(try json(payload) == #"{"activity":"agentChat","environment":"production","pushToStartToken":null,"pushToken":null}"#)
        #expect(payload.isEnded)
    }

    @Test("the payload decodes from what another platform writes, with the keys absent")
    func payloadDecodes() throws {
        let decoded = try MessageCodec.decode(
            ActivityTokenPayload.self,
            from: Data(#"{"activity":"agentChat","pushToStartToken":"ff","environment":"production"}"#.utf8)
        )
        #expect(decoded == ActivityTokenPayload(activity: .agentChat, pushToken: nil, pushToStartToken: "ff", environment: .production))
    }

    @Test("the tokens go only to a host that declared it")
    func supportGate() {
        #expect(LiveActivityPushSupport.maySend(toHostDeclared: true))
        #expect(!LiveActivityPushSupport.maySend(toHostDeclared: false))
        #expect(!LiveActivityPushSupport.maySend(toHostDeclared: nil))
    }

    @Test("a server hello without the flag decodes as not supported and one with it as supported")
    func helloFlag() throws {
        let old = #"{"serverID":"s","hostName":"Mac","protocolVersion":20,"alreadyPaired":true}"#
        #expect(try MessageCodec.decode(ServerHello.self, from: Data(old.utf8)).supportsLiveActivityPush == nil)
        let new = #"{"serverID":"s","hostName":"Mac","protocolVersion":20,"alreadyPaired":true,"supportsLiveActivityPush":true}"#
        #expect(try MessageCodec.decode(ServerHello.self, from: Data(new.utf8)).supportsLiveActivityPush == true)
    }

    @Test("only hex of even length is a plausible token")
    func plausibleTokens() {
        #expect(LiveActivityPushSupport.isPlausible("0a1B"))
        #expect(!LiveActivityPushSupport.isPlausible(""))
        #expect(!LiveActivityPushSupport.isPlausible("abc"))
        #expect(!LiveActivityPushSupport.isPlausible("zz"))
        #expect(LiveActivityPushSupport.hex(Data([0x00, 0xAB])) == "00ab")
    }

    @Test("an update writes the relay's notifyActivity shape")
    func notifyActivityUpdate() throws {
        let push = RelayActivityPush(
            activityToken: "abcd",
            activity: .session,
            event: .update,
            contentState: .object(["phase": .string("active"), "startedAt": .number(1_760_000_000)]),
            staleSeconds: 120,
            environment: .production
        )
        let encoded = String(decoding: try RelayMessageCodec.encode(RelayClientMessage.notifyActivity(push)), as: UTF8.self)
        #expect(encoded == #"{"activity":"session","activityToken":"abcd","contentState":{"phase":"active","startedAt":1760000000},"environment":"production","event":"update","staleSeconds":120,"type":"notifyActivity"}"#)
    }

    @Test("a start carries the attributes and the alert")
    func notifyActivityStart() throws {
        let push = RelayActivityPush(
            activityToken: "ee",
            activity: .agentChat,
            event: .start,
            contentState: .object([:]),
            priority: 10,
            attributesType: "AgentChatActivityAttributes",
            attributes: .object(["origin": .string("host")]),
            alertTitle: "t",
            alertBody: "b",
            environment: .sandbox
        )
        let encoded = String(decoding: try RelayMessageCodec.encode(RelayClientMessage.notifyActivity(push)), as: UTF8.self)
        #expect(encoded == #"{"activity":"agentChat","activityToken":"ee","alertBody":"b","alertTitle":"t","attributes":{"origin":"host"},"attributesType":"AgentChatActivityAttributes","contentState":{},"environment":"sandbox","event":"start","priority":10,"type":"notifyActivity"}"#)
    }

    @Test("a state past 3500 bytes does not fit")
    func contentStateLimit() {
        let small = RelayActivityPush(activityToken: "a", activity: .session, event: .update, contentState: .object(["a": .string("b")]), environment: .production)
        let large = RelayActivityPush(activityToken: "a", activity: .session, event: .update, contentState: .object(["a": .string(String(repeating: "x", count: 3600))]), environment: .production)
        #expect(small.contentStateFits)
        #expect(!large.contentStateFits)
    }

    @Test("activityRefused decodes every reason, and one the relay adds later")
    func refusalDecodes() throws {
        func decode(_ reason: String) throws -> RelayServerMessage {
            let body = "{\"type\":\"activityRefused\",\"reason\":\"" + reason + "\"}"
            return try RelayMessageCodec.decode(RelayServerMessage.self, from: Data(body.utf8))
        }
        #expect(try decode("invalidToken") == .activityRefused(.invalidToken))
        #expect(try decode("invalidPayload") == .activityRefused(.invalidPayload))
        #expect(try decode("rejected") == .activityRefused(.rejected))
        #expect(try decode("unavailable") == .activityRefused(.unavailable))
        #expect(try decode("tooBusy") == .activityRefused(.other("tooBusy")))
    }

    @Test("the published frame vectors decode, and frame with kind 0x24")
    func publishedVectors() throws {
        let session = #"{"activity":"session","environment":"production","pushToStartToken":null,"pushToken":"0a1b2c"}"#
        let decoded = try MessageCodec.decode(ActivityTokenPayload.self, from: Data(session.utf8))
        #expect(decoded == ActivityTokenPayload(activity: .session, pushToken: "0a1b2c", pushToStartToken: nil, environment: .production))
        let framed = FrameEncoder.encode(Frame(kind: .activityToken, payload: Data(session.utf8)))
        #expect(framed.prefix(5).map { String(format: "%02x", $0) }.joined() == "0000005f24")
    }
}
