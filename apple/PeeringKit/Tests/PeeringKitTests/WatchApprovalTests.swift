import Foundation
import RemoteCore
import Testing
import WatchLink
@testable import PeeringKit

struct WatchApprovalTests {
    private let session = UUID()
    private let moment = Date(timeIntervalSince1970: 5_000)

    private func notification(name: String = "Bash", detail: String? = "rm -rf build", questions: [AgentQuestion]? = nil) -> AgentApprovalNotification {
        AgentApprovalNotification(
            approval: AgentApproval(id: "A1", call: AgentToolCall(id: "C1", name: name, title: name, detail: detail, questions: questions), reason: nil),
            sessionID: session
        )
    }

    private func question(_ labels: [String]) -> AgentQuestion {
        AgentQuestion(question: "Which?", options: labels.map { AgentToolOption(label: $0) })
    }

    @Test func aToolApprovalReachesTheWatchAsAllowDeny() {
        let made = notification().watchApproval(chatTitle: "Fix build", hostID: "h", hostName: "Studio", postedAt: moment)
        #expect(made.kind == .allowDeny)
        #expect(made.body == "rm -rf build")
        #expect(made.chatTitle == "Fix build")
        #expect(made.sessionID == session)
    }

    @Test func aQuestionKeepsItsFullAnswers() {
        let made = notification(name: "AskUserQuestion", questions: [question(["Blue", "Green"])])
            .watchApproval(chatTitle: "t", hostID: nil, hostName: nil, postedAt: moment)
        #expect(made.kind == .options)
        #expect(made.answers == ["Blue", "Green"])
    }

    @Test func aPlanCannotBeAnsweredOnTheWrist() {
        let made = notification(name: "ExitPlanMode", detail: nil).watchApproval(chatTitle: "t", hostID: nil, hostName: nil, postedAt: moment)
        #expect(made.kind == .openOnly)
    }

    @Test func aWatchAnswerBecomesTheDecisionTheLockScreenButtonWouldMake() throws {
        let made = notification(name: "AskUserQuestion", questions: [question(["Blue", "Green"])])
            .watchApproval(chatTitle: "t", hostID: nil, hostName: nil, postedAt: moment)
        let choices = made.choices(allowTitle: "Allow", denyTitle: "Deny")
        let second = made.answer(try #require(choices.last))
        let decision = AgentApprovalNotification.decision(forActionIdentifier: second.actionIdentifier, answers: second.answers)
        #expect(decision == .choose(["Green"]))

        let tool = notification().watchApproval(chatTitle: "t", hostID: nil, hostName: nil, postedAt: moment)
        let allow = try #require(tool.choices(allowTitle: "Allow", denyTitle: "Deny").last)
        let toolAnswer = tool.answer(allow)
        #expect(AgentApprovalNotification.decision(forActionIdentifier: toolAnswer.actionIdentifier, answers: []) == .allow)
    }

    @Test func theWatchSpeaksTheSameNotificationVocabularyAsThePhone() {
        typealias Shape = WatchApproval.NotificationShape
        #expect(Shape.identifierPrefix == AgentApprovalNotification.identifierPrefix)
        #expect(Shape.toolCategory == AgentApprovalNotification.toolCategory)
        #expect(Shape.yesNoCategory == AgentApprovalNotification.yesNoCategory)
        #expect(AgentApprovalNotification.openCategory.hasPrefix(Shape.categoryPrefix))
        #expect(AgentApprovalNotification.optionsCategoryPrefix.hasPrefix(Shape.categoryPrefix))
        #expect(Shape.approvalIDKey == AgentApprovalNotification.UserInfoKey.approvalID)
        #expect(Shape.sessionIDKey == AgentApprovalNotification.UserInfoKey.sessionID)
        #expect(Shape.hostIDKey == AgentApprovalNotification.UserInfoKey.hostID)
        #expect(Shape.answersKey == AgentApprovalNotification.UserInfoKey.answers)
        #expect(WatchApproval.allowIdentifier == AgentApprovalNotification.allowIdentifier)
        #expect(WatchApproval.denyIdentifier == AgentApprovalNotification.denyIdentifier)
        #expect(WatchApproval.optionPrefix == AgentApprovalNotification.optionPrefix)
    }
}
