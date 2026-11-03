import Foundation
import RemoteCore
import Testing
@testable import PeeringKit

struct AgentQuestionChainTests {
    private let session = UUID()

    private func ask(_ questions: [[String]]) -> AgentApproval {
        let asked = questions.enumerated().map { index, labels in
            AgentQuestion(question: "Q\(index + 1)?", options: labels.map { AgentToolOption(label: $0) })
        }
        return AgentApproval(
            id: "A1",
            call: AgentToolCall(id: "C1", name: "AskUserQuestion", title: "AskUserQuestion", detail: nil, questions: asked),
            reason: nil
        )
    }

    private func firstReference(_ questions: [[String]]) -> AgentApprovalNotification.Reference {
        AgentApprovalNotification(approval: ask(questions), sessionID: session).reference(hostID: "H")
    }

    @Test func severalQuestionsStartWithTheFirstOnesAnswers() {
        let note = AgentApprovalNotification(approval: ask([["Red", "Blue"], ["Big", "Small", "Tiny"]]), sessionID: session)
        #expect(note.layout == .options(["Red", "Blue"]))
        #expect(note.bannerBody == "(1/2) Q1?")
        #expect(note.categoryIdentifier == "peering.agent.approval.options.A1.0")
    }

    @Test func anAnswerBeforeTheLastPostsTheNextQuestion() {
        let outcome = firstReference([["Red", "Blue"], ["Big", "Small"]]).outcome(forActionIdentifier: "choose.1")
        guard case .next(let next) = outcome else { Issue.record("expected the next question"); return }
        #expect(next.step == 1)
        #expect(next.chosen == ["Blue"])
        #expect(next.layoutForCategory == .options(["Big", "Small"]))
        #expect(next.stepBody == "(2/2) Q2?")
        #expect(next.categoryIdentifier == "peering.agent.approval.options.A1.1")
    }

    @Test func theLastAnswerSendsEveryAnswerInOrder() {
        var reference = firstReference([["Red", "Blue"], ["Big", "Small"], ["Yes", "No"]])
        for pick in ["choose.0", "choose.1"] {
            guard case .next(let next) = reference.outcome(forActionIdentifier: pick) else { Issue.record("expected next"); return }
            reference = next
        }
        #expect(reference.outcome(forActionIdentifier: "choose.1") == .answer(.choose(["Red", "Small", "No"])))
    }

    @Test func aChainSurvivesTheNotificationPayload() {
        guard case .next(let next) = firstReference([["Red", "Blue"], ["Big", "Small"]]).outcome(forActionIdentifier: "choose.0") else {
            Issue.record("expected next"); return
        }
        let restored = AgentApprovalNotification.Reference(userInfo: AgentApprovalNotification.Reference.userInfo(for: next))
        #expect(restored == next)
    }

    @Test func aPushedChainNeedsNoAnswersOfItsOwn() {
        guard let chain = AgentQuestionChain(questions: ask([["Red", "Blue"], ["Big"]]).call.questions ?? []) else {
            Issue.record("expected a chain"); return
        }
        let info: [AnyHashable: Any] = ["agentApprovalId": "A1", "agentSessionId": session.uuidString, "agentQuestions": chain.payload]
        let reference = AgentApprovalNotification.Reference(userInfo: info)
        #expect(reference?.layoutForCategory == .options(["Red", "Blue"]))
        #expect(reference?.answers == ["Red", "Blue"])
    }

    @Test func openAndDismissAreNotAnswers() {
        let reference = firstReference([["Red", "Blue"], ["Big", "Small"]])
        #expect(reference.outcome(forActionIdentifier: "open") == .none)
        #expect(reference.outcome(forActionIdentifier: "choose.7") == .none)
    }

    @Test func aQuestionWithTooManyAnswersIsNoChain() {
        #expect(AgentQuestionChain(questions: ask([["1", "2", "3", "4", "5"], ["a"]]).call.questions ?? []) == nil)
        #expect(AgentQuestionChain(questions: ask([["a", "b"]]).call.questions ?? []) == nil)
    }

    @Test func theWatchIsToldToOpenAChain() {
        let note = AgentApprovalNotification(approval: ask([["Red", "Blue"], ["Big"]]), sessionID: session)
        let watch = note.watchApproval(chatTitle: "Chat", hostID: nil, hostName: nil, postedAt: Date(timeIntervalSince1970: 0))
        #expect(watch.kind == .openOnly)
        #expect(watch.answers.isEmpty)
    }

    @Test func pushesCarryTheChainButKeepTheOpenCategory() {
        let call = ask([["Red", "Blue"], ["Big"]]).call
        #expect(AgentApprovalNotification.pushCategory(for: call) == AgentApprovalNotification.openCategory)
        #expect(AgentApprovalNotification.pushQuestions(for: call)?.steps.count == 2)
    }

    @Test func aQuestionTooLongForTheRelayIsNotPushed() {
        let long = String(repeating: "x", count: 600)
        let chain = AgentQuestionChain(steps: [.init(question: long, answers: ["a"]), .init(question: "b", answers: ["c"])])
        #expect(chain?.relayQuestions.isEmpty == true)
    }
}
