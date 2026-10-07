import Foundation
import MacCastKit
import RemoteCore
import SwiftUI

extension MacSession {
    func announceAgentChange(at index: Int, from before: AgentSessionState) {
        let session = agentSessions[index]
        if before == .awaitingApproval, session.transcript.state != before, session.isLoaded {
            InAppBanner.shared.resolve(chatID: session.id)
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
            let options = approval.call.options?.map(\.label) ?? []
            let sessionID = session.id
            item = InAppBannerItem(
                symbol: options.isEmpty ? "hand.raised.fill" : "questionmark.bubble.fill",
                title: session.title,
                summary: options.isEmpty ? approval.call.title : String(localized: "Asks a question"),
                body: approval.reason ?? approval.call.detail,
                needsYou: true,
                chatID: sessionID,
                options: options,
                respond: { [weak self] decision in
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
                chatID: session.id
            )
        case .failed:
            item = InAppBannerItem(
                symbol: "exclamationmark.triangle.fill",
                title: session.title,
                summary: String(localized: "The chat stopped with an error."),
                body: session.failure,
                needsYou: true,
                chatID: session.id
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
            case .idle: state = .ready
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
