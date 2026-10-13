import Foundation
import RemoteCore
import Testing
@testable import PeeringKit

struct AgentApprovalNotificationTests {
    private let session = UUID()

    private func approval(
        name: String = "Bash",
        detail: String? = "rm -rf build",
        reason: String? = nil,
        questions: [AgentQuestion]? = nil
    ) -> AgentApproval {
        AgentApproval(
            id: "A1",
            call: AgentToolCall(id: "C1", name: name, title: name, detail: detail, questions: questions),
            reason: reason
        )
    }

    private func question(_ labels: [String]) -> AgentQuestion {
        AgentQuestion(question: "Which?", options: labels.map { AgentToolOption(label: $0) })
    }

    @Test func aToolApprovalOffersAllowAndDeny() {
        let note = AgentApprovalNotification(approval: approval(), sessionID: session)
        #expect(note.layout == .allowDeny)
        #expect(note.actions.map(\.title) == [.deny, .allow])
        #expect(note.categoryIdentifier == "peering.agent.approval.tool")
    }

    @Test func allowNeedsAuthenticationAndNothingElseDoes() {
        let tool = AgentApprovalNotification(approval: approval(), sessionID: session).actions
        #expect(tool.first { $0.title == .allow }?.requiresAuthentication == true)
        #expect(tool.first { $0.title == .deny }?.requiresAuthentication == false)
        #expect(tool.allSatisfy { !$0.opensApp })
    }

    @Test func aSingleQuestionOffersOneButtonPerAnswer() {
        let note = AgentApprovalNotification(
            approval: approval(name: "AskUserQuestion", questions: [question(["Yes", "No", "Later"])]),
            sessionID: session
        )
        #expect(note.layout == .options(["Yes", "No", "Later"]))
        #expect(note.actions.map(\.identifier) == ["choose.0", "choose.1", "choose.2"])
        #expect(note.categoryIdentifier == "peering.agent.approval.options.A1")
    }

    @Test func moreAnswersThanFitFallBackToOpen() {
        let note = AgentApprovalNotification(
            approval: approval(name: "AskUserQuestion", questions: [question(["1", "2", "3", "4", "5"])]),
            sessionID: session
        )
        #expect(note.layout == .openOnly)
        #expect(note.actions.map(\.title) == [.open])
        #expect(note.actions.allSatisfy { $0.opensApp })
    }

    @Test func severalQuestionsAndPlansOnlyOpen() {
        let several = AgentApprovalNotification(
            approval: approval(name: "AskUserQuestion", questions: [question(["a"]), question(["b"])]),
            sessionID: session
        )
        let plan = AgentApprovalNotification(approval: approval(name: "ExitPlanMode"), sessionID: session)
        #expect(several.layout == .openOnly)
        #expect(plan.layout == .openOnly)
        #expect(plan.isPlan)
    }

    @Test func aLongAnswerKeepsItsFullLabelInTheDecision() {
        let long = String(repeating: "x", count: 90)
        let note = AgentApprovalNotification(
            approval: approval(name: "AskUserQuestion", questions: [question([long])]),
            sessionID: session
        )
        guard case .option(let title) = note.actions[0].title else { Issue.record("expected an option"); return }
        #expect(title.count == AgentApprovalNotification.maxOptionTitleLength)
        #expect(AgentApprovalNotification.decision(forActionIdentifier: "choose.0", answers: note.answers) == .choose([long]))
    }

    @Test func actionIdentifiersMapToDecisions() {
        #expect(AgentApprovalNotification.decision(forActionIdentifier: "allow", answers: []) == .allow)
        #expect(AgentApprovalNotification.decision(forActionIdentifier: "deny", answers: []) == .deny)
        #expect(AgentApprovalNotification.decision(forActionIdentifier: "choose.1", answers: ["a", "b"]) == .choose(["b"]))
    }

    @Test func openAndUnknownActionsAreNotAnswers() {
        #expect(AgentApprovalNotification.decision(forActionIdentifier: "open", answers: []) == nil)
        #expect(AgentApprovalNotification.decision(forActionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", answers: []) == nil)
        #expect(AgentApprovalNotification.decision(forActionIdentifier: "choose.5", answers: ["a"]) == nil)
        #expect(AgentApprovalNotification.decision(forActionIdentifier: "choose.x", answers: ["a"]) == nil)
    }

    @Test func theBodyLeadsWithTheCommandAndIsCut() {
        let reasoned = AgentApprovalNotification(approval: approval(detail: "rm -rf build", reason: "Deletes the build folder"), sessionID: session)
        #expect(reasoned.body == "rm -rf build\n\nDeletes the build folder")
        let long = AgentApprovalNotification(approval: approval(detail: String(repeating: "a", count: 1000)), sessionID: session)
        #expect(long.body.count == AgentApprovalNotification.maxBodyLength)
        #expect(long.body.hasSuffix("\u{2026}"))
    }

    @Test func truncationLeavesShortTextAlone() {
        #expect(AgentApprovalNotification.truncated("  ls  ") == "ls")
        #expect(AgentApprovalNotification.truncated("abcdef", limit: 6) == "abcdef")
        #expect(AgentApprovalNotification.truncated("abcdefg", limit: 6) == "abcde\u{2026}")
    }

    @Test func userInfoRoundTrips() throws {
        let note = AgentApprovalNotification(
            approval: approval(name: "AskUserQuestion", questions: [question(["Yes", "No"])]),
            sessionID: session
        )
        let info = note.userInfo(hostID: "MAC-1", answers: note.answers)
        let reference = try #require(AgentApprovalNotification.Reference(userInfo: info))
        #expect(reference.approvalID == "A1")
        #expect(reference.sessionID == session)
        #expect(reference.hostID == "MAC-1")
        #expect(reference.layoutForCategory == .options(["Yes", "No"]))
    }

    @Test func aCommandTheBannerWouldCutShortCannotBeAllowedFromTheLockScreen() {
        let fits = AgentApprovalNotification(approval: approval(detail: String(repeating: "a", count: 239)), sessionID: session)
        let cut = AgentApprovalNotification(approval: approval(detail: String(repeating: "a", count: 240)), sessionID: session)
        #expect(fits.layout == .allowDeny)
        #expect(cut.layout == .openOnly)
        #expect(cut.actions.map(\.title) == [.open])
    }

    @Test func aToolWithNoCommandToShowCannotBeAllowedFromTheLockScreen() {
        let note = AgentApprovalNotification(approval: approval(name: "mcp__x__run", detail: nil, reason: "Needs approval"), sessionID: session)
        #expect(note.layout == .openOnly)
    }

    @Test func aPayloadWithoutOurKeysIsNotAnApproval() {
        #expect(AgentApprovalNotification.Reference(userInfo: ["hostId": "MAC-1"]) == nil)
        #expect(AgentApprovalNotification.Reference(userInfo: ["agentApprovalId": "A1", "agentSessionId": "nope"]) == nil)
    }

    @Test func aPushNamesOnlyTheCategoriesThePhoneRegisters() {
        let tool = AgentToolCall(id: "c", name: "Bash", title: "Bash", detail: "ls")
        let asking = AgentToolCall(id: "c", name: "AskUserQuestion", title: "Q", questions: [question(["a", "b"])])
        #expect(AgentApprovalNotification.pushCategory(for: tool) == "peering.agent.approval.tool")
        #expect(AgentApprovalNotification.pushCategory(for: asking) == "peering.agent.approval.open")
    }

    @Test func aPushedYesOrNoQuestionGetsYesAndNoButtons() {
        let asking = AgentToolCall(id: "c", name: "AskUserQuestion", title: "Q", questions: [question(["Yes", "No"])])
        let reversed = AgentToolCall(id: "c", name: "AskUserQuestion", title: "Q", questions: [question([" no", "YES"])])
        #expect(AgentApprovalNotification.pushCategory(for: asking) == "peering.agent.approval.yesno")
        #expect(AgentApprovalNotification.pushCategory(for: reversed) == "peering.agent.approval.yesno")
        #expect(AgentApprovalNotification.yesNoActions.map(\.title) == [.no, .yes])
    }

    @Test func theYesAndNoButtonsAnswerTheQuestion() {
        #expect(AgentApprovalNotification.decision(forActionIdentifier: "yes", answers: []) == .choose(["Yes"]))
        #expect(AgentApprovalNotification.decision(forActionIdentifier: "no", answers: []) == .choose(["No"]))
    }

    @Test func theNotificationIdentifierIsFoundByItsPrefix() {
        let note = AgentApprovalNotification(approval: approval(), sessionID: session)
        #expect(AgentApprovalNotification.isApprovalIdentifier(note.identifier))
        #expect(!AgentApprovalNotification.isApprovalIdentifier("peering-terminal-1"))
    }
}
