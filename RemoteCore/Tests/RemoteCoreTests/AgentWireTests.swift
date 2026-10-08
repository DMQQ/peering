import Foundation
import Testing

@testable import RemoteCore

@Suite("Agent wire protocol")
struct AgentWireTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private let turnSummary = AgentTurnSummary(
        ok: true,
        stopped: false,
        costUSD: 0.4217,
        inputTokens: 12_408,
        outputTokens: 1_902,
        duration: 72.4,
        model: "claude-sonnet-5-5"
    )

    @Test("usage round-trips in a listing and as an event, and an older listing decodes without it")
    func usageRoundTrips() throws {
        let id = UUID()
        let usage = AgentUsage(
            contextUsedTokens: 84_000, contextWindowTokens: 1_000_000,
            inputTokens: 16_000, cachedTokens: 41_000, outputTokens: 900, costUSD: 0.07,
            limits: [AgentUsageLimit(label: "5 hours", usedFraction: 0.07, resetsAt: Date(timeIntervalSince1970: 1_791_286_200))]
        )
        let info = AgentSessionInfo(
            id: id, agentID: "claude", title: "Claude Code", directory: "/tmp", state: .idle, lastIndex: 0,
            usage: usage, createdAt: Date(timeIntervalSince1970: 0)
        )
        #expect(try roundTrip(info) == info)
        let event = AgentEvent.usageChanged(sessionID: id, usage: usage)
        #expect(try roundTrip(event) == event)

        let older = Data(
            #"{"id":"\#(id.uuidString)","agentID":"codex","title":"Codex","directory":"/tmp","state":"idle","lastIndex":0,"createdAt":0}"#.utf8
        )
        #expect(try MessageCodec.decode(AgentSessionInfo.self, from: older).usage == nil)
    }

    @Test("permission modes round-trip, and a listing from an older Mac decodes without them")
    func permissionModesRoundTrip() throws {
        let id = UUID()
        let info = AgentSessionInfo(
            id: id, agentID: "claude", title: "Claude Code", directory: "/tmp", state: .idle, lastIndex: 0,
            permissionMode: .acceptEdits, permissionModes: [.manual, .acceptEdits],
            createdAt: Date(timeIntervalSince1970: 0)
        )
        #expect(try roundTrip(info) == info)
        let request = AgentRequest.setPermissionMode(sessionID: id, mode: .auto)
        #expect(try roundTrip(request) == request)
        let event = AgentEvent.permissionModeChanged(sessionID: id, mode: .manual)
        #expect(try roundTrip(event) == event)

        let older = Data(
            #"{"id":"\#(id.uuidString)","agentID":"codex","title":"Codex","directory":"/tmp","state":"idle","lastIndex":0,"createdAt":0}"#.utf8
        )
        let decoded = try MessageCodec.decode(AgentSessionInfo.self, from: older)
        #expect(decoded.permissionMode == nil)
        #expect(decoded.permissionModes == nil)
    }

    @Test("client requests round-trip, home folder included")
    func requestsRoundTrip() throws {
        let id = UUID(uuidString: "3E3F0A9A-2B77-4C55-9E4A-6F7A2D8E1B30")!
        let requests: [AgentRequest] = [
            .list,
            .history(sessionID: id, since: 0),
            .history(sessionID: id, since: 4_182),
            .start(agentID: "claude", directory: "/Users/someone/projects/app"),
            .start(agentID: "codex", directory: nil),
            .prompt(sessionID: id, text: "Fix the failing test on line 42"),
            .approval(sessionID: id, approvalID: "req_011C", decision: .allow),
            .approval(sessionID: id, approvalID: "req_011C", decision: .deny),
            .approval(sessionID: id, approvalID: "req_011D", decision: .choose(["Blue", "Small"])),
            .interrupt(sessionID: id),
            .setModel(sessionID: id, model: "sonnet"),
            .setModel(sessionID: id, model: nil),
            .close(sessionID: id),
            .browse(path: nil),
            .browse(path: "/Users/someone"),
        ]
        for request in requests {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test("host events round-trip with listings, stream, replay and browse")
    func eventsRoundTrip() throws {
        let id = UUID(uuidString: "9A1C4E6E-0B2D-4F8A-8C31-5D9E7B2A4C60")!
        let info = AgentSessionInfo(
            id: id,
            agentID: "claude",
            title: "Claude Code · app",
            directory: "/Users/someone/projects/app",
            state: .awaitingApproval,
            lastIndex: 42,
            model: "claude-sonnet-4-5-20250929",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let events: [AgentEvent] = [
            .snapshot([info]),
            .snapshot([]),
            .created(info),
            .stream(sessionID: id, event: AgentStreamEvent(index: 7, payload: .turnStarted)),
            .replay(
                sessionID: id,
                events: [AgentStreamEvent(index: 7, payload: .turnStarted)],
                isLast: false,
                truncatedAtFront: true
            ),
            .directory(
                path: "/Users/someone/projects",
                entries: [
                    RemoteDirectoryEntry(
                        name: "app",
                        isDirectory: true,
                        isSymlink: false,
                        size: 128,
                        permissions: "drwxr-xr-x",
                        modified: Date(timeIntervalSince1970: 1_790_000_000)
                    )
                ],
                truncated: false
            ),
            .browseFailure(path: "/nope", message: "There is no folder there."),
            .closed(sessionID: id),
            .modelChanged(sessionID: id, model: "claude-opus-5-5"),
            .modelChanged(sessionID: id, model: nil),
            .failed(sessionID: id, message: "The Claude Code process ended."),
            .failed(sessionID: nil, message: "Agent session limit reached."),
        ]
        for event in events {
            #expect(try roundTrip(event) == event)
        }
    }

    @Test("every stream event payload round-trips")
    func streamPayloadsRoundTrip() throws {
        let call = AgentToolCall(
            id: "toolu_01",
            name: "Bash",
            title: "Bash",
            detail: "npm test",
            filePath: nil,
            diff: nil
        )
        let edit = AgentToolCall(
            id: "toolu_02",
            name: "Edit",
            title: "Edit",
            detail: "/Users/someone/app/src/a.ts",
            filePath: "/Users/someone/app/src/a.ts",
            diff: "@@ -1,3 +1,3 @@\n-old\n+new\n"
        )
        let payloads: [AgentStreamEvent.Payload] = [
            .sessionReady(agentID: "claude", cliSessionID: "76f6f3a1-3b6c", model: "claude-opus-5-5", directory: "/tmp"),
            .sessionReady(agentID: "codex", cliSessionID: nil, model: nil, directory: "/tmp"),
            .userPrompt(text: "Run the tests"),
            .turnStarted,
            .textDelta(text: "Running "),
            .textFinal(text: "Running the tests now."),
            .toolStarted(call: call),
            .toolStarted(call: AgentToolCall(id: "toolu_03", name: "TodoWrite", title: "TodoWrite")),
            .toolStarted(call: edit),
            .toolFinished(callID: call.id, ok: true, output: "24 tests passed\n", truncated: false),
            .toolFinished(callID: call.id, ok: false, output: nil, truncated: false),
            .toolFinished(callID: call.id, ok: true, output: String(repeating: "x", count: 64), truncated: true),
            .approvalRequested(approvalID: "req_011C", call: call, reason: "Bash is not in the allow list."),
            .approvalRequested(approvalID: "req_011D", call: call, reason: nil),
            .approvalRequested(
                approvalID: "req_011E",
                call: AgentToolCall(
                    id: "toolu_q1",
                    name: "AskUserQuestion",
                    title: "Colour",
                    detail: "Which colour do you prefer?",
                    questions: [
                        AgentQuestion(header: "Colour", question: "Which colour do you prefer?", options: [
                            AgentToolOption(label: "Red", detail: "You prefer red."),
                            AgentToolOption(label: "Blue"),
                        ]),
                        AgentQuestion(question: "Which size?", options: [AgentToolOption(label: "Small")]),
                    ]
                ),
                reason: nil
            ),
            .approvalResolved(approvalID: "req_011C", decision: .allow),
            .approvalResolved(approvalID: "req_011D", decision: .deny),
            .turnFinished(summary: turnSummary),
            .turnFinished(summary: AgentTurnSummary(ok: false, stopped: true)),
            .notice(text: "Interrupted."),
            .failure(message: "claude exited with status 1"),
            .sessionExited(status: 0),
        ]
        for payload in payloads {
            let event = AgentStreamEvent(index: 1, payload: payload)
            #expect(try roundTrip(event) == event)
        }
    }

    @Test("agent frames have distinct stable message kinds")
    func messageKinds() {
        #expect(MessageKind.agentRequest.rawValue == 0x1E)
        #expect(MessageKind.agentEvent.rawValue == 0x1F)
        #expect(MessageKind.allCases.contains(.agentRequest))
        #expect(MessageKind.allCases.contains(.agentEvent))
    }

    @Test("only an explicit chat capability permits traffic")
    func capabilityGate() {
        #expect(AgentChatSupport.maySend(toHostDeclared: true))
        #expect(!AgentChatSupport.maySend(toHostDeclared: nil))
        #expect(!AgentChatSupport.maySend(toHostDeclared: false))

        #expect(AgentChatSupport.mayReceive(clientDeclared: true))
        #expect(!AgentChatSupport.mayReceive(clientDeclared: nil))
        #expect(!AgentChatSupport.mayReceive(clientDeclared: false))
    }
}
