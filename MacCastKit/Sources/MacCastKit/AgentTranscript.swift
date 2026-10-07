import Foundation
import RemoteCore

public struct AgentApproval: Equatable, Identifiable {
    public let id: String
    public let call: AgentToolCall
    public let reason: String?
}

public struct AgentToolItem: Equatable {
    public var call: AgentToolCall
    public var state: State
    public var output: String?
    public var truncated: Bool

    public enum State: Equatable {
        case running
        /// Waiting on the user, naming the approval the answer must echo.
        case awaitingApproval(id: String)
        case denied
        case ok
        case failed
    }
}

public enum AgentTranscriptItem: Equatable, Identifiable {
    case user(id: UUID, text: String)
    case reply(id: UUID, text: String)
    case tool(id: UUID, item: AgentToolItem)
    case notice(id: UUID, text: String)
    case failure(id: UUID, text: String)
    case summary(id: UUID, summary: AgentTurnSummary)

    public var id: UUID {
        switch self {
        case .user(let id, _), .reply(let id, _), .tool(let id, _),
             .notice(let id, _), .failure(let id, _), .summary(let id, _):
            return id
        }
    }
}

/// A session's conversation, rebuilt from the event stream.
public struct AgentTranscript: Equatable {
    public private(set) var items: [AgentTranscriptItem] = []
    public private(set) var state: AgentSessionState = .idle
    public private(set) var pendingApprovals: [AgentApproval] = []
    public private(set) var lastIndex: UInt64 = 0
    /// Set when the Mac could not replay the start of the conversation, so the panel can say the
    /// transcript begins mid-story rather than pretending it does not.
    public private(set) var truncatedAtFront = false

    /// Kept as it arrives: a card in a list reads it on every streamed event, and finding it by walking the whole conversation each time was most of that cost.
    public private(set) var latestPlan: [AgentPlanStep]?

    /// What each sub-agent did, keyed by the id of the `Task` call that spawned it.
    public private(set) var children: [String: AgentTranscript] = [:]

    /// When a sub-agent's first event arrived here, so a row can say how long it has been running. Replayed history gets the replay's time, which only matters while it is still running.
    public private(set) var startedAt: Date?

    private var openReplyID: UUID?
    /// An approximate total of the text held, kept so trimming does not walk the whole list on
    /// every token.
    private var bytes = 0

    public init() {}

    private init(startedAt: Date) {
        self.startedAt = startedAt
    }

    public var isEmpty: Bool { items.isEmpty }

    /// The Mac's turnStarted is a round trip away; the thinking row should not wait for it.
    public mutating func markPromptSent() {
        state = .working
    }

    public mutating func reset() {
        self = AgentTranscript()
    }

    /// Applies a whole replay, in order. Events already applied are ignored, so a live event that
    /// raced the replay is not drawn twice.
    public mutating func apply(_ events: [AgentStreamEvent]) {
        for event in events { apply(event) }
    }

    public mutating func apply(_ event: AgentStreamEvent) {
        guard event.index > lastIndex else { return }
        lastIndex = event.index
        apply(event.payload)
    }

    public mutating func apply(_ payload: AgentStreamEvent.Payload) {
        switch payload {
        case .sessionReady:
            break

        case .userPrompt(let text):
            openReplyID = nil
            append(.user(id: UUID(), text: text), bytes: text.utf8.count)

        case .turnStarted:
            state = .working

        case .textDelta(let text):
            if let id = openReplyID, let index = items.firstIndex(where: { $0.id == id }),
               case .reply(let replyID, let existing) = items[index] {
                let grown = existing + text
                bytes += text.utf8.count
                items[index] = .reply(id: replyID, text: grown)
            } else {
                let id = UUID()
                openReplyID = id
                append(.reply(id: id, text: text), bytes: text.utf8.count)
            }
            state = .working

        case .textFinal(let text):
            // The whole block, which is what the deltas were building. Replacing rather than
            // appending is the point: a dropped or duplicated delta cannot corrupt the answer.
            if let id = openReplyID, let index = items.firstIndex(where: { $0.id == id }),
               case .reply(let replyID, let existing) = items[index] {
                bytes += text.utf8.count - existing.utf8.count
                items[index] = .reply(id: replyID, text: text)
            } else {
                append(.reply(id: UUID(), text: text), bytes: text.utf8.count)
            }
            openReplyID = nil

        case .toolStarted(let call):
            openReplyID = nil
            if let plan = call.plan, !plan.isEmpty { latestPlan = plan }
            append(.tool(id: UUID(), item: AgentToolItem(call: call, state: .running, output: nil, truncated: false)), bytes: 0)
            state = .working

        case .toolFinished(let callID, let ok, let output, let truncated):
            guard let index = items.firstIndex(where: { item in
                if case .tool(_, let tool) = item { return tool.call.id == callID }
                return false
            }), case .tool(let id, var tool) = items[index] else { return }
            tool.state = ok ? .ok : .failed
            children[callID]?.state = .idle
            tool.output = output
            tool.truncated = truncated
            items[index] = .tool(id: id, item: tool)
            bytes += (output ?? "").utf8.count

        case .approvalRequested(let approvalID, let call, let reason):
            pendingApprovals.append(AgentApproval(id: approvalID, call: call, reason: reason))
            let existing = items.firstIndex(where: { item in
                if case .tool(_, let tool) = item { return tool.call.id == call.id }
                return false
            })
            if let index = existing, case .tool(let id, var tool) = items[index] {
                tool.state = .awaitingApproval(id: approvalID)
                items[index] = .tool(id: id, item: tool)
            } else {
                let tool = AgentToolItem(call: call, state: .awaitingApproval(id: approvalID), output: nil, truncated: false)
                append(.tool(id: UUID(), item: tool), bytes: 0)
            }
            state = .awaitingApproval

        case .approvalResolved(let approvalID, let decision):
            pendingApprovals.removeAll { $0.id == approvalID }
            for index in items.indices {
                guard case .tool(let id, var tool) = items[index],
                      tool.state == .awaitingApproval(id: approvalID) else { continue }
                // A deny is the only answer that stops the call: a chosen option is an allow with
                // a payload, and the tool then runs with it.
                if case .deny = decision {
                    tool.state = .denied
                } else {
                    tool.state = .running
                }
                items[index] = .tool(id: id, item: tool)
            }
            if pendingApprovals.isEmpty { state = .working }

        case .turnFinished(let summary):
            openReplyID = nil
            // A finished turn cannot still be waiting on anything: the CLI cancels the asks it
            // was holding, and a bar that outlives its turn is a button that answers nothing.
            pendingApprovals = []
            append(.summary(id: UUID(), summary: summary), bytes: 0)
            state = .idle

        case .notice(let text):
            append(.notice(id: UUID(), text: text), bytes: text.utf8.count)

        case .failure(let message):
            append(.failure(id: UUID(), text: message), bytes: message.utf8.count)
            state = .failed

        case .sessionExited:
            state = .exited

        case .child(let parentCallID, let event):
            if children[parentCallID] == nil { children[parentCallID] = AgentTranscript(startedAt: Date()) }
            children[parentCallID]?.apply(event)
            // A sub-agent has no turns of its own: it works until the call that spawned it finishes.
            children[parentCallID]?.state = .working
        }
    }

    public mutating func markTruncatedAtFront() {
        truncatedAtFront = true
    }

    private mutating func append(_ item: AgentTranscriptItem, bytes added: Int) {
        items.append(item)
        bytes += added
        trimIfNeeded()
    }

    /// Drops whole turns from the front once the transcript outgrows its budget.
    private mutating func trimIfNeeded() {
        guard bytes > AgentLimits.maximumTranscriptBytes else { return }
        let turnStarts = items.indices.filter { index in
            if case .user = items[index] { return true }
            return false
        }
        guard turnStarts.count > 1, let cut = turnStarts.dropFirst().first else { return }
        let dropped = items[0..<cut]
        bytes -= dropped.reduce(0) { $0 + Self.approximateBytes(of: $1) }
        items.removeFirst(cut)
        truncatedAtFront = true
    }

    private static func approximateBytes(of item: AgentTranscriptItem) -> Int {
        switch item {
        case .user(_, let text), .reply(_, let text), .notice(_, let text), .failure(_, let text):
            return text.utf8.count
        case .tool(_, let tool):
            return (tool.output ?? "").utf8.count + (tool.call.diff ?? "").utf8.count
                + (tool.call.detail ?? "").utf8.count
        case .summary:
            return 0
        }
    }

    public var runningSubagents: [(call: AgentToolCall, transcript: AgentTranscript)] {
        subagents.filter { $0.transcript.state == .working }
    }

    /// The sub-agents of this conversation in the order they were spawned, with the call each belongs to.
    public var subagents: [(call: AgentToolCall, transcript: AgentTranscript)] {
        items.compactMap { item in
            guard case .tool(_, let tool) = item, let child = children[tool.call.id] else { return nil }
            return (tool.call, child)
        }
    }
}
