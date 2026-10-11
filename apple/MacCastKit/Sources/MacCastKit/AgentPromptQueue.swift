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
