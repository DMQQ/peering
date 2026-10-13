#if DEBUG
import Foundation
import PeeringKit
import RemoteCore

/// Which chat the UI tests find on launch, chosen by `-Peering.seedAgentScenario <name>`; with none, ``AgentSeed`` draws the App Store capture.
enum AgentSeedScenario: String {
    case bashAsk
    case questionAsk
    case working
    case empty
    case threeLive

    static var requested: AgentSeedScenario? {
        UserDefaults.standard.string(forKey: "Peering.seedAgentScenario").flatMap(Self.init(rawValue:))
    }
}

extension AgentSeed {
    /// With `-Peering.seedFakeMac 1` the phone behaves as if a Mac were connected, so chats can be driven with no host. Nothing goes on a wire; ``MacSession/answerSeededApproval(_:decision:in:)`` and ``MacSession/startSeededChat(directory:)`` stand in for the Mac's replies.
    static var wantsFakeMac: Bool {
        isRequested && UserDefaults.standard.bool(forKey: "Peering.seedFakeMac")
    }

    static func seedID(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "5EED0000-0000-4000-8000-%012d", number))!
    }

    static func scenarioSessions(_ scenario: AgentSeedScenario) -> [RemoteAgentSession] {
        switch scenario {
        case .bashAsk:
            return [chat(1, "orders-service", state: .awaitingApproval, payloads: asked(bashCall, reason: "Runs the project's test suite, which writes to the build folder."))]
        case .questionAsk:
            return [chat(1, "orders-service", state: .awaitingApproval, payloads: asked(questionCall, reason: nil))]
        case .working:
            return [chat(1, "orders-service", state: .working, payloads: [
                .userPrompt(text: "Add a discount to orders over $100."),
                .turnStarted,
            ])]
        case .empty:
            return [chat(1, "orders-service", state: .idle, payloads: [])]
        case .threeLive:
            return ["api", "web", "docs"].enumerated().map { chat($0.offset + 1, $0.element, state: .idle, payloads: []) }
        }
    }

    static func newChat(number: Int, directory: String) -> RemoteAgentSession {
        chat(number, "new chat", state: .idle, payloads: [], directory: directory)
    }

    private static func chat(
        _ number: Int,
        _ folder: String,
        state: AgentSessionState,
        payloads: [AgentStreamEvent.Payload],
        directory: String? = nil
    ) -> RemoteAgentSession {
        let info = AgentSessionInfo(
            id: seedID(number),
            agentID: "claude",
            title: "Claude Code · \(folder)",
            directory: directory ?? "/Users/demo/\(folder)",
            state: state,
            lastIndex: 0,
            model: "claude-opus-5-5",
            permissionMode: .manual,
            permissionModes: [.manual, .acceptEdits, .auto],
            createdAt: .now - 600
        )
        var session = RemoteAgentSession(info)
        for payload in payloads { session.transcript.apply(payload) }
        session.isLoaded = true
        return session
    }

    private static func asked(_ call: AgentToolCall, reason: String?) -> [AgentStreamEvent.Payload] {
        [
            .userPrompt(text: "Get the orders service ready to ship."),
            .turnStarted,
            .approvalRequested(approvalID: "a1", call: call, reason: reason),
        ]
    }

    private static let bashCall = AgentToolCall(id: "t1", name: "Bash", title: "Run npm test", detail: "npm test --workspace orders")

    private static let questionCall = AgentToolCall(
        id: "q1", name: "AskUserQuestion", title: "Asks a question",
        questions: [
            AgentQuestion(header: "Database", question: "Which database should orders use?", options: [
                AgentToolOption(label: "Postgres"), AgentToolOption(label: "SQLite"),
            ]),
            AgentQuestion(header: "Auth", question: "How should callers authenticate?", options: [
                AgentToolOption(label: "API key"), AgentToolOption(label: "OAuth"),
            ]),
            AgentQuestion(header: "Deploy", question: "Where should it deploy?", options: [
                AgentToolOption(label: "Fly.io"), AgentToolOption(label: "Render"),
            ]),
        ]
    )
}

extension MacSession {
    /// The Mac's reply to an answer: the ask is resolved and a notice names what was sent, so a test can read what reached the wire.
    func answerSeededApproval(_ approvalID: String, decision: AgentApprovalDecision, in id: UUID) {
        guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
        let sent: String
        switch decision {
        case .allow: sent = "allow"
        case .deny: sent = "deny"
        case .choose(let answers): sent = answers.joined(separator: ", ")
        }
        agentSessions[index].transcript.apply(.approvalResolved(approvalID: approvalID, decision: decision))
        agentSessions[index].transcript.apply(.notice(text: "Answered: \(sent)"))
        refreshAgentCards()
    }

    func startSeededChat(directory: String?) {
        let session = AgentSeed.newChat(number: 100 + agentSessions.count, directory: directory ?? "/Users/demo/new")
        agentSessions.append(session)
        refreshAgentCards()
    }

    /// Answers a listing the way the Mac would: a request naming no path is the home folder.
    func answerSeededListing(_ path: String?, sessionID id: UUID) {
        let resolved = path ?? "/Users/demo"
        let folder = { (name: String) in
            RemoteDirectoryEntry(name: name, isDirectory: true, isSymlink: false, size: 0, permissions: "drwxr-xr-x", modified: nil)
        }
        let file = { (name: String) in
            RemoteDirectoryEntry(name: name, isDirectory: false, isSymlink: false, size: 2048, permissions: "-rw-r--r--", modified: nil)
        }
        let entries = resolved == "/Users/demo"
            ? [folder("Documents"), folder("Downloads"), folder("Projects"), file("notes.txt")]
            : [folder("orders-service"), file("README.md")]
        let listing = RemoteDirectory(entries: entries, isTruncated: false)
        directories[RemoteDirectoryKey(terminalID: id, path: path)] = listing
        directories[RemoteDirectoryKey(terminalID: id, path: resolved)] = listing
        if browsingPaths[id] == nil { browsingPaths[id] = resolved }
    }

    /// A file whose first line is far wider than the screen, so wrapping can be told from scrolling.
    func answerSeededPreview(_ path: String, sessionID id: UUID) {
        let wide = "const readings = [" + (1...40).map { "\($0 * 137)" }.joined(separator: ", ") + "];"
        let text = (["// notes", wide] + (1...60).map { "line \($0): some ordinary text" }).joined(separator: "\n")
        let data = Data(text.utf8)
        filePreview = RemoteFilePreview(terminalID: id, path: path, totalBytes: data.count, data: data, isComplete: true)
    }

    /// A Mac that is only a name and a set of capabilities.
    func becomeSeededMac() {
        phase = .ready
        hasBeenReady = true
        hostName = "Demo Mac"
        hostSupportsAgentList = true
        hostSupportsFileBrowser = true
        hostSupportsAgentChat = true
        hostSupportsAgentModelPicker = true
        hostSupportsAgentPermissionModes = true
        refreshAgentCards()
    }
}

extension SessionModel {
    func installSeededMac() {
        guard AgentSeed.wantsFakeMac else { return }
        let session = MacSession(model: self, renderer: renderer)
        place(session, replacing: nil)
        session.becomeSeededMac()
    }
}
#endif
