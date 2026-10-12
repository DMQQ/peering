import Foundation
import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

extension MacSession {
    func announceAgentChange(at index: Int, from before: AgentSessionState) {
        let session = agentSessions[index]
        if before == .awaitingApproval, session.transcript.state != before, session.isLoaded {
            InAppBanner.shared.resolve(chatID: session.id)
        }
        if before == .awaitingApproval {
            let pending = Set(session.transcript.pendingApprovals.map(\.id))
            AgentApprovalNotifier.shared.retain(pending: pending, in: session.id)
        }
        guard let announcement = AgentAnnouncement.of(
            from: before,
            to: session.transcript.state,
            isLoaded: session.isLoaded,
            transcript: session.transcript
        ) else { return }
        let item: InAppBannerItem
        switch announcement {
        case .approval(let approval):
            let questions = approval.call.questions ?? []
            // Cards in the banner answer one question; a longer ask is opened in the chat.
            let options = questions.count == 1 ? questions[0].options.map(\.label) : []
            let asksSeveral = questions.count > 1
            let sessionID = session.id
            announceApprovalOnLockScreen(approval, in: session)
            item = InAppBannerItem(
                symbol: options.isEmpty && !asksSeveral ? "hand.raised.fill" : "questionmark.bubble.fill",
                title: session.title,
                summary: options.isEmpty && !asksSeveral ? approval.call.title : String(localized: "Asks a question"),
                body: AgentApprovalBody.text(command: approval.call.detail, reason: approval.reason),
                needsYou: true,
                target: .chat(sessionID),
                options: options,
                respond: asksSeveral ? nil : { [weak self] decision in
                    self?.respondToAgentApproval(approval.id, decision: decision, in: sessionID)
                }
            )
        case .finished(let reply):
            item = InAppBannerItem(
                symbol: "checkmark.circle.fill",
                title: session.title,
                summary: String(localized: "Finished"),
                body: reply,
                needsYou: false,
                target: .chat(session.id)
            )
        case .failed:
            item = InAppBannerItem(
                symbol: "exclamationmark.triangle.fill",
                title: session.title,
                summary: String(localized: "The chat stopped with an error."),
                body: HostWireText.localized(session.failure),
                needsYou: true,
                target: .chat(session.id)
            )
        }
        InAppBanner.shared.post(item)
    }
}

extension MacSession {
    /// The chats as the widget draws them. Called after every agent event; the publisher drops what changed nothing.
    func publishAgentWidget() {
        let chats = agentSessions.compactMap { session -> AgentChatSnapshot? in
            let state: AgentChatSnapshot.State
            switch session.state {
            case .working: state = .working
            case .awaitingApproval: state = .needsYou
            case .idle: state = .finished
            case .failed: state = .failed
            case .exited: return nil
            }
            let plan = session.transcript.planProgress
            let agent = TerminalAgent.all.first { $0.id == session.agentID }
            let folder = (session.directory as NSString).lastPathComponent
            return AgentChatSnapshot(
                id: session.id.uuidString,
                hostID: hostID,
                title: session.title,
                symbol: agent?.symbol ?? "sparkles",
                folder: folder.isEmpty ? session.directory : folder,
                state: state,
                activity: session.transcript.activity,
                planDone: plan?.completed ?? 0,
                planTotal: plan?.total ?? 0,
                planStepNumber: plan?.currentNumber,
                planStep: plan?.current?.text,
                updatedAt: .now
            )
        }
        AgentWidgetPublisher.shared.update(hostKey: hostID ?? hostName ?? id.uuidString, chats: chats)
    }
}

extension MacSession {
    /// Only without a push token: the Mac's push carries the same buttons, and a local copy beside it would be two banners for one question.
    private func announceApprovalOnLockScreen(_ approval: AgentApproval, in session: RemoteAgentSession) {
        guard UIApplication.shared.applicationState != .active, SessionNotifier.shared.remoteToken == nil else { return }
        let notification = AgentApprovalNotification(approval: approval, sessionID: session.id)
        let (title, hostID, hostName) = (session.title, self.hostID, self.shownName)
        Task { await AgentApprovalNotifier.shared.post(notification, sessionTitle: title, hostID: hostID, hostName: hostName) }
    }
}
