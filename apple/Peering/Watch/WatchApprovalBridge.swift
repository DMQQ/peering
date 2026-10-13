import Foundation
import PeeringKit
import RemoteCore
import WatchConnectivity
import WatchLink
import os

private nonisolated let watchLog = Logger(subsystem: "pl.dmq.peering", category: "watch")

/// Hands the questions agents are waiting on to the paired watch and carries its answers back to the Mac.
@MainActor
final class WatchApprovalBridge: NSObject {
    static let shared = WatchApprovalBridge()

    private let link: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    private var waiting: [String: [WatchApproval]] = [:]
    /// When each question was first seen, so the order on the wrist is stable and republishing the same list changes nothing.
    private var firstSeen: [String: Date] = [:]
    private var sent: [WatchApproval]?

    private override init() { super.init() }

    func activate() {
        guard let link else { return }
        link.delegate = self
        link.activate()
    }

    /// The questions one Mac's chats are waiting on, replacing what this Mac had published before.
    func update(hostKey: String, approvals: [WatchApproval]) {
        waiting[hostKey] = approvals.isEmpty ? nil : approvals
        publish()
    }

    private func publish() {
        guard let link, link.activationState == .activated, link.isPaired, link.isWatchAppInstalled else { return }
        let current = waiting.values.flatMap { $0 }
        let ids = Set(current.map(\.approvalID))
        firstSeen = firstSeen.filter { ids.contains($0.key) }
        let now = Date()
        let stamped = current.map { approval -> WatchApproval in
            let moment = firstSeen[approval.approvalID] ?? now
            firstSeen[approval.approvalID] = moment
            return approval.posted(at: moment)
        }.sorted { $0.postedAt > $1.postedAt }
        guard stamped != sent else { return }
        do {
            try link.updateApplicationContext(WatchApprovalSnapshot(approvals: stamped, sentAt: now).context)
            sent = stamped
        } catch {
            watchLog.error("could not hand the questions to the watch: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func deliver(_ answer: WatchAnswer) async -> Bool {
        guard let decision = AgentApprovalNotification.decision(forActionIdentifier: answer.actionIdentifier, answers: answer.answers) else { return false }
        let reference = AgentApprovalNotification.Reference(
            approvalID: answer.approvalID, sessionID: answer.sessionID, hostID: answer.hostID, answers: answer.answers
        )
        return await AgentApprovalResponder.answer(decision, to: reference)
    }
}

/// WatchConnectivity hands the reply block over without marking it Sendable; it is called once, from the task that waited for the Mac.
private nonisolated struct Reply: @unchecked Sendable {
    let send: ([String: Any]) -> Void
}

extension WatchApprovalBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error { watchLog.error("the watch link did not start: \(error.localizedDescription, privacy: .public)") }
        Task { @MainActor in publish() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            sent = nil
            publish()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = Reply(send: replyHandler)
        guard let answer = WatchAnswer(message: message) else {
            reply.send(WatchAnswerReply.payload(delivered: false))
            return
        }
        Task { @MainActor in
            let delivered = await Self.deliver(answer)
            reply.send(WatchAnswerReply.payload(delivered: delivered))
        }
    }
}
