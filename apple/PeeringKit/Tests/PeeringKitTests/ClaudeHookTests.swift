import Foundation
import RemoteCore
import Testing
@testable import PeeringKit

struct ClaudeHookTests {
    private let command = "\"/Users/x/Library/Application Support/pl.dmq.peering.host/peering-hook\""

    private func line(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - Event

    @Test func aBashPermissionRequestCarriesItsCommandAndFolder() throws {
        let event = try #require(ClaudeHookEvent.parse(line("""
        {"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/Users/x/code/app",
         "tool_name":"Bash","tool_input":{"command":"rm -rf build"}}
        """)))
        #expect(event.kind == .permissionRequest)
        #expect(event.detail == "rm -rf build")
        #expect(event.projectName == "app")
        #expect(event.canBeAnsweredFromANotification)
    }

    @Test func aFileToolShowsItsPath() throws {
        let event = try #require(ClaudeHookEvent.parse(line("""
        {"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Edit",
         "tool_input":{"file_path":"/a/b.swift","old_string":"x"}}
        """)))
        #expect(event.detail == "/a/b.swift")
    }

    @Test func aQuestionIsLeftToTheApp() throws {
        let event = try #require(ClaudeHookEvent.parse(line("""
        {"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"AskUserQuestion","tool_input":{}}
        """)))
        #expect(!event.canBeAnsweredFromANotification)
    }

    @Test func aNotificationIsNotAnApproval() throws {
        let event = try #require(ClaudeHookEvent.parse(line("""
        {"hook_event_name":"Notification","session_id":"s1","message":"Claude is waiting for your input"}
        """)))
        #expect(event.kind == .notification)
        #expect(event.message == "Claude is waiting for your input")
        #expect(!event.canBeAnsweredFromANotification)
    }

    @Test func anIdlePromptIsPushedAsTheTurnFinishing() throws {
        let event = try #require(ClaudeHookEvent.parse(line("""
        {"hook_event_name":"Notification","session_id":"s1","cwd":"/work/app","notification_type":"idle_prompt","message":"Claude is waiting for your input"}
        """)))
        #expect(event.notificationType == "idle_prompt")
        let pushed = PushedText()
        let broker = ClaudeHookBroker(tokens: { ["token"] }, push: { _, title, body, _ in pushed.set(title, body) })
        broker.handle(event, reply: { _ in })
        #expect(pushed.title == "Claude Code in app finished")
        #expect(pushed.body == "The turn finished.")
    }

    @Test func otherNotificationsKeepClaudeCodesOwnWords() throws {
        let event = try #require(ClaudeHookEvent.parse(line("""
        {"hook_event_name":"Notification","session_id":"s1","cwd":"/work/app","notification_type":"elicitation_dialog","message":"Claude needs your input"}
        """)))
        let pushed = PushedText()
        let broker = ClaudeHookBroker(tokens: { ["token"] }, push: { _, title, body, _ in pushed.set(title, body) })
        broker.handle(event, reply: { _ in })
        #expect(pushed.body == "Claude needs your input")
    }

    @Test func aLineWithoutASessionIsRefused() {
        #expect(ClaudeHookEvent.parse(line(#"{"hook_event_name":"Stop"}"#)) == nil)
        #expect(ClaudeHookEvent.parse(line("not json")) == nil)
    }

    // MARK: - Reply

    @Test func anAllowReplyNamesTheEventAndTheBehaviour() throws {
        let object = try #require(JSONSerialization.jsonObject(with: ClaudeHookReply.permission(.allow)) as? [String: Any])
        let output = try #require(object["hookSpecificOutput"] as? [String: Any])
        let decision = try #require(output["decision"] as? [String: Any])
        #expect(output["hookEventName"] as? String == "PermissionRequest")
        #expect(decision["behavior"] as? String == "allow")
    }

    @Test func aDenyReplySaysWhy() throws {
        let object = try #require(JSONSerialization.jsonObject(with: ClaudeHookReply.permission(.deny)) as? [String: Any])
        let decision = try #require(((object["hookSpecificOutput"] as? [String: Any])?["decision"]) as? [String: Any])
        #expect(decision["behavior"] as? String == "deny")
        #expect(decision["message"] as? String != nil)
    }

    // MARK: - Settings

    @Test func installingKeepsEverythingElse() throws {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": ["PermissionRequest": [["hooks": [["type": "command", "command": "/usr/local/bin/mine"]]]]],
        ]
        let result = try ClaudeHookSettings.installing(command: command, into: existing)
        #expect(result["model"] as? String == "opus")
        let groups = try #require((result["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])
        #expect(groups.count == 2)
        #expect(ClaudeHookSettings.isInstalled(in: result))
    }

    @Test func installingTwiceDoesNotDuplicate() throws {
        let once = try ClaudeHookSettings.installing(command: command, into: [:])
        let twice = try ClaudeHookSettings.installing(command: command, into: once)
        let groups = try #require((twice["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])
        #expect(groups.count == 1)
    }

    @Test func removingLeavesTheUsersOwnHooksAndDropsEmptyEvents() throws {
        let existing: [String: Any] = [
            "hooks": ["PermissionRequest": [["hooks": [["type": "command", "command": "/usr/local/bin/mine"]]]]],
        ]
        let installed = try ClaudeHookSettings.installing(command: command, into: existing)
        let removed = try ClaudeHookSettings.removing(from: installed)
        let hooks = try #require(removed["hooks"] as? [String: Any])
        #expect(hooks["Notification"] == nil)
        #expect((hooks["PermissionRequest"] as? [[String: Any]])?.count == 1)
        #expect(!ClaudeHookSettings.isInstalled(in: removed))
    }

    @Test func removingFromAnEmptyFileLeavesItEmpty() throws {
        let installed = try ClaudeHookSettings.installing(command: command, into: [:])
        #expect(try ClaudeHookSettings.removing(from: installed).isEmpty)
    }

    @Test func aShapeItDoesNotKnowIsRefused() {
        #expect(throws: ClaudeHookSettings.Failure.unexpectedShape("hooks")) {
            try ClaudeHookSettings.installing(command: command, into: ["hooks": "nope"])
        }
        #expect(throws: ClaudeHookSettings.Failure.unexpectedShape("hooks.Notification")) {
            try ClaudeHookSettings.installing(command: command, into: ["hooks": ["Notification": "nope"]])
        }
    }
}

struct ClaudeHookBrokerTests {
    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var pushes: [(title: String, body: String, action: RelayPushAction?)] = []
        var replies: [Data?] = []
        var timers: [@Sendable () -> Void] = []
    }

    private let recorder = Recorder()

    private func broker(tokens: [String] = ["t1"]) -> ClaudeHookBroker {
        let recorder = recorder
        return ClaudeHookBroker(
            tokens: { tokens },
            push: { _, title, body, action in recorder.lock.withLock { recorder.pushes.append((title, body, action)) } },
            schedule: { _, work in recorder.lock.withLock { recorder.timers.append(work) } }
        )
    }

    private func event(tool: String = "Bash", command: String = "npm test") -> ClaudeHookEvent {
        ClaudeHookEvent(
            kind: .permissionRequest, sessionID: UUID().uuidString, directory: "/Users/x/app",
            toolName: tool, detail: command, message: nil
        )
    }

    private var firstReply: Data? { recorder.replies.first ?? nil }

    private func handle(_ broker: ClaudeHookBroker, _ event: ClaudeHookEvent) {
        let recorder = recorder
        broker.handle(event) { reply in recorder.lock.withLock { recorder.replies.append(reply) } }
    }

    @Test func aCommandIsHeldAndPushedWithAllowAndDeny() throws {
        let broker = broker()
        handle(broker, event())
        #expect(recorder.replies.isEmpty)
        let action = try #require(recorder.pushes.first?.action)
        #expect(action.category == AgentApprovalNotification.toolCategory)
        #expect(recorder.pushes.first?.title == "Claude Code in app asks")
    }

    @Test func allowAnswersTheHeldHookOnce() throws {
        let broker = broker()
        handle(broker, event())
        let approvalID = try #require(recorder.pushes.first?.action?.approvalID)
        #expect(broker.resolve(approvalID: approvalID, decision: .allow))
        #expect(recorder.replies.count == 1)
        #expect(firstReply == ClaudeHookReply.permission(.allow))
        #expect(!broker.resolve(approvalID: approvalID, decision: .deny))
    }

    @Test func denyAnswersWithADeny() throws {
        let broker = broker()
        handle(broker, event())
        let approvalID = try #require(recorder.pushes.first?.action?.approvalID)
        _ = broker.resolve(approvalID: approvalID, decision: .deny)
        #expect(firstReply == ClaudeHookReply.permission(.deny))
    }

    @Test func aRequestNobodyTookFallsBackToTheTerminalDialog() throws {
        let broker = broker()
        handle(broker, event())
        let timer = try #require(recorder.timers.first)
        timer()
        #expect(recorder.replies.count == 1)
        #expect(firstReply == nil)
    }

    @Test func aLateTapAfterTheTimeoutFindsNothing() throws {
        let broker = broker()
        handle(broker, event())
        let approvalID = try #require(recorder.pushes.first?.action?.approvalID)
        let timer = try #require(recorder.timers.first)
        timer()
        #expect(!broker.resolve(approvalID: approvalID, decision: .allow))
    }

    @Test func noPhoneMeansNoWait() {
        let broker = broker(tokens: [])
        handle(broker, event())
        #expect(recorder.replies.count == 1)
        #expect(recorder.pushes.isEmpty)
    }

    @Test func aQuestionIsPushedButNeverHeld() {
        let broker = broker()
        handle(broker, event(tool: "AskUserQuestion", command: ""))
        #expect(recorder.replies.count == 1)
        #expect(recorder.pushes.first?.action?.category == AgentApprovalNotification.openCategory)
    }

    @Test func aCommandTooLongToReadIsLeftToTheApp() {
        let broker = broker()
        handle(broker, event(command: String(repeating: "x", count: 400)))
        #expect(recorder.replies.count == 1)
        #expect(recorder.pushes.first?.action?.category == AgentApprovalNotification.openCategory)
    }

    @Test func anIdleNotificationIsAPlainPush() {
        let broker = broker()
        let idle = ClaudeHookEvent(kind: .notification, sessionID: "s", directory: nil, toolName: nil, detail: nil, message: "Claude is waiting for your input")
        handle(broker, idle)
        #expect(recorder.pushes.first?.body == "Claude is waiting for your input")
        #expect(recorder.pushes.first?.action == nil)
        #expect(recorder.replies.count == 1)
    }
}

private final class PushedText: @unchecked Sendable {
    private let lock = NSLock()
    private var _title = ""
    private var _body = ""

    func set(_ title: String, _ body: String) {
        lock.withLock {
            _title = title
            _body = body
        }
    }

    var title: String { lock.withLock { _title } }
    var body: String { lock.withLock { _body } }
}
