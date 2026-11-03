import Foundation
import RemoteCore

/// Messages typed while a turn runs. The Mac takes one question at a time, so the rest wait here and go out as each turn ends.
public struct AgentPromptQueue: Equatable {
    public private(set) var prompts: [String] = []

    public enum Submission: Equatable {
        case send
        case queued
    }

    public enum Release: Equatable {
        case send(String)
        case hold
        case dropped
    }

    public init() {}

    public init(prompts: [String]) {
        self.prompts = prompts
    }

    /// Behind a turn in flight, or behind messages already waiting: order is the order typed.
    public mutating func submit(_ text: String, sessionState: AgentSessionState?) -> Submission {
        if sessionState == .working || sessionState == .awaitingApproval || !prompts.isEmpty {
            prompts.append(text)
            return .queued
        }
        return .send
    }

    public mutating func remove(at offset: Int) {
        guard prompts.indices.contains(offset) else { return }
        prompts.remove(at: offset)
    }

    /// Removes the message the sender saw at `offset`. The queue may have moved since (a turn ended and released the first), so a different message there means the sender's view is stale and the same text is looked for instead.
    @discardableResult
    public mutating func remove(_ text: String, at offset: Int) -> Bool {
        if prompts.indices.contains(offset), prompts[offset] == text {
            prompts.remove(at: offset)
            return true
        }
        guard let moved = prompts.firstIndex(of: text) else { return false }
        prompts.remove(at: moved)
        return true
    }

    /// A chat that failed or ended will never answer, so what waited for it is not sent into the next one.
    public mutating func release(state: AgentSessionState) -> Release {
        guard !prompts.isEmpty else { return .hold }
        switch state {
        case .idle:
            return .send(prompts.removeFirst())
        case .failed, .exited:
            prompts.removeAll()
            return .dropped
        case .working, .awaitingApproval:
            return .hold
        }
    }
}
