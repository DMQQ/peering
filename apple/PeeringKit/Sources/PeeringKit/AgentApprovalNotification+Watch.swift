import Foundation
import WatchLink

extension AgentApprovalNotification {
    /// What the watch is shown for this question. The watch gets the same layout the lock screen would, so a question it cannot answer is marked as one to open on the phone.
    public func watchApproval(chatTitle: String, hostID: String?, hostName: String?, postedAt: Date) -> WatchApproval {
        let kind: WatchApproval.Kind
        // The watch answers in one tap, so a chain's first answer alone would reach the Mac as the whole reply.
        switch chain == nil ? layout : .openOnly {
        case .allowDeny: kind = .allowDeny
        case .options: kind = .options
        case .openOnly: kind = .openOnly
        }
        return WatchApproval(
            approvalID: approvalID,
            sessionID: sessionID,
            hostID: hostID,
            chatTitle: chatTitle,
            hostName: hostName,
            body: body,
            kind: kind,
            answers: chain == nil ? answers : [],
            postedAt: postedAt
        )
    }
}
