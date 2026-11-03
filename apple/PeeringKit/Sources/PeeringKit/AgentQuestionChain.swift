import Foundation
import RemoteCore

/// An ask of several questions answered from the lock screen one notification at a time: each answer posts the next
/// question, and the last one sends every answer together, as the app's own sheet does.
public struct AgentQuestionChain: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public let question: String
        public let answers: [String]

        public init(question: String, answers: [String]) {
            self.question = question
            self.answers = answers
        }
    }

    public static let maxQuestions = 4

    public let steps: [Step]

    /// Nil unless there are several questions and every one fits a notification's buttons.
    public init?(questions: [AgentQuestion]) {
        guard (2...Self.maxQuestions).contains(questions.count) else { return nil }
        var steps: [Step] = []
        for question in questions {
            let labels = question.options.map(\.label).filter { !$0.isEmpty }
            guard (1...AgentApprovalNotification.maxOptionActions).contains(labels.count) else { return nil }
            steps.append(Step(question: question.question, answers: labels))
        }
        self.steps = steps
    }

    public init?(steps: [Step]) {
        guard (2...Self.maxQuestions).contains(steps.count),
              steps.allSatisfy({ (1...AgentApprovalNotification.maxOptionActions).contains($0.answers.count) })
        else { return nil }
        self.steps = steps
    }

    /// What a banner says for one step: which question of how many, then the question itself.
    public func body(at step: Int) -> String {
        guard steps.indices.contains(step) else { return "" }
        let text = "(\(step + 1)/\(steps.count)) " + steps[step].question
        return AgentApprovalNotification.truncated(text)
    }

    // MARK: - Payload

    /// What a push carries, or nothing when a question is too long for the relay, which would refuse the whole push.
    public var relayQuestions: [RelayPushQuestion] {
        let questions = steps.map { RelayPushQuestion(question: $0.question, answers: $0.answers) }
        return questions.allSatisfy(\.fitsTheRelay) ? questions : []
    }

    private enum Key {
        static let question = "q"
        static let answers = "a"
    }

    /// The shape a push and a notification's `userInfo` carry: `[{"q": question, "a": [answers]}]`.
    public var payload: [[String: Any]] {
        steps.map { [Key.question: $0.question, Key.answers: $0.answers] }
    }

    public init?(payload: Any?) {
        guard let entries = payload as? [[String: Any]] else { return nil }
        var steps: [Step] = []
        for entry in entries {
            guard let question = entry[Key.question] as? String, let answers = entry[Key.answers] as? [String] else { return nil }
            steps.append(Step(question: question, answers: answers))
        }
        self.init(steps: steps)
    }
}

extension AgentApprovalNotification.Reference {
    /// What a tapped button on a notification leads to.
    public enum Outcome: Equatable, Sendable {
        /// Send this answer to the Mac.
        case answer(AgentApprovalDecision)
        /// Post the next question of a chain, carrying the answers chosen so far.
        case next(AgentApprovalNotification.Reference)
        /// Open, a dismissal, or a button that is not an answer.
        case none
    }

    public func outcome(forActionIdentifier identifier: String) -> Outcome {
        guard let chain, chain.steps.indices.contains(step) else {
            return AgentApprovalNotification.decision(forActionIdentifier: identifier, answers: answers).map(Outcome.answer) ?? .none
        }
        guard case .choose(let picked)? = AgentApprovalNotification.decision(
            forActionIdentifier: identifier, answers: chain.steps[step].answers
        ) else { return .none }
        let soFar = chosen + picked
        guard step + 1 < chain.steps.count else { return .answer(.choose(soFar)) }
        return .next(advanced(choosing: soFar))
    }

    private func advanced(choosing soFar: [String]) -> Self {
        Self(approvalID: approvalID, sessionID: sessionID, hostID: hostID,
             answers: chain?.steps[step + 1].answers ?? [], chain: chain, step: step + 1, chosen: soFar)
    }

    /// The category this notification's buttons live in: one per step of a chain, since each step has its own answers.
    public var categoryIdentifier: String {
        let key = chain == nil ? approvalID : approvalID + "." + String(step)
        return AgentApprovalNotification.categoryIdentifier(forLayout: layoutForCategory, approvalID: key)
    }

    /// The banner text for a chain's current step, nil outside a chain.
    public var stepBody: String? {
        chain?.body(at: step)
    }
}
