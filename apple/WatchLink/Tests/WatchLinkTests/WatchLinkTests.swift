import Foundation
import Testing
@testable import WatchLink

private let session = UUID(uuidString: "8E2B1D84-0000-4000-8000-000000000001")!

private func approval(kind: WatchApproval.Kind, answers: [String] = []) -> WatchApproval {
    WatchApproval(
        approvalID: "a1", sessionID: session, hostID: "host", chatTitle: "Fix build", hostName: "Studio",
        body: "rm -rf build", kind: kind, answers: answers, postedAt: Date(timeIntervalSince1970: 1_000)
    )
}

@Suite("Watch approvals")
struct WatchLinkTests {
    @Test func snapshotSurvivesTheContextDictionary() throws {
        let snapshot = WatchApprovalSnapshot(approvals: [approval(kind: .allowDeny)], sentAt: Date(timeIntervalSince1970: 2_000))
        let decoded = try #require(WatchApprovalSnapshot(context: snapshot.context))
        #expect(decoded == snapshot)
    }

    @Test func aContextWithoutOurKeyIsNotASnapshot() {
        #expect(WatchApprovalSnapshot(context: ["other": 1]) == nil)
    }

    @Test func answerSurvivesTheMessageDictionary() throws {
        let choice = try #require(approval(kind: .allowDeny).choices(allowTitle: "Allow", denyTitle: "Deny").last)
        let answer = approval(kind: .allowDeny).answer(choice)
        #expect(answer.actionIdentifier == "allow")
        #expect(try #require(WatchAnswer(message: answer.message)) == answer)
    }

    @Test func allowDenyPutsDenyFirst() {
        let choices = approval(kind: .allowDeny).choices(allowTitle: "Allow", denyTitle: "Deny")
        #expect(choices.map(\.actionIdentifier) == ["deny", "allow"])
        #expect(choices.map(\.label) == ["Deny", "Allow"])
    }

    @Test func optionsAreNumberedInTheOrderTheyAreShown() {
        let choices = approval(kind: .options, answers: ["Blue", "Green"]).choices(allowTitle: "Allow", denyTitle: "Deny")
        #expect(choices.map(\.actionIdentifier) == ["choose.0", "choose.1"])
        #expect(choices.map(\.label) == ["Blue", "Green"])
    }

    @Test func aPlanOffersNoButtons() {
        #expect(approval(kind: .openOnly).choices(allowTitle: "Allow", denyTitle: "Deny").isEmpty)
    }

    @Test func restampingChangesOnlyTheTime() {
        let original = approval(kind: .allowDeny)
        let later = original.posted(at: Date(timeIntervalSince1970: 9_000))
        #expect(later.postedAt == Date(timeIntervalSince1970: 9_000))
        #expect(later.posted(at: original.postedAt) == original)
    }

    @Test func replyReadsDelivered() {
        #expect(WatchAnswerReply.isDelivered(WatchAnswerReply.payload(delivered: true)))
        #expect(!WatchAnswerReply.isDelivered(WatchAnswerReply.payload(delivered: false)))
        #expect(!WatchAnswerReply.isDelivered([:]))
    }

    @Test func aMirroredToolNotificationBecomesAllowDeny() throws {
        let made = try #require(notification(category: "peering.agent.approval.tool", userInfo: baseInfo))
        #expect(made.kind == .allowDeny)
        #expect(made.hostName == "Studio")
        #expect(made.hostID == "host")
    }

    @Test func aMirroredQuestionKeepsItsAnswers() throws {
        var info = baseInfo
        info["agentAnswers"] = ["Blue", "Green"]
        let made = try #require(notification(category: "peering.agent.approval.options.a1", userInfo: info))
        #expect(made.kind == .options)
        #expect(made.answers == ["Blue", "Green"])
    }

    @Test func aPushedYesNoQuestionGetsYesAndNo() throws {
        let made = try #require(notification(category: "peering.agent.approval.yesno", userInfo: baseInfo))
        #expect(made.kind == .options)
        #expect(made.answers == ["Yes", "No"])
    }

    @Test func anOpenOnlyNotificationCannotBeAnsweredOnTheWrist() throws {
        let made = try #require(notification(category: "peering.agent.approval.open", userInfo: baseInfo))
        #expect(made.kind == .openOnly)
    }

    @Test func otherNotificationsAreIgnored() {
        #expect(notification(category: "peering.agent.finished", userInfo: baseInfo) == nil)
        #expect(notification(category: "peering.agent.approval.tool", userInfo: [:]) == nil)
        #expect(notification(identifier: "something-else", category: "peering.agent.approval.tool", userInfo: baseInfo) == nil)
    }

    private var baseInfo: [AnyHashable: Any] {
        ["agentApprovalId": "a1", "agentSessionId": session.uuidString, "hostId": "host"]
    }

    private func notification(identifier: String = "peering-agent-approval-a1", category: String, userInfo: [AnyHashable: Any]) -> WatchApproval? {
        WatchApproval(
            notificationIdentifier: identifier, category: category, title: "Fix build", subtitle: "Studio",
            body: "rm -rf build", userInfo: userInfo, date: Date(timeIntervalSince1970: 1_000)
        )
    }
}
