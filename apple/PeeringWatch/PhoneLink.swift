import Foundation
import WatchConnectivity
import WatchLink

/// The watch's end of the link to the phone: what the phone has waiting arrives here, and answers leave from here.
final class PhoneLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    /// Called with the phone's list whenever it changes and once at start, from a background queue.
    var onSnapshot: (@Sendable (WatchApprovalSnapshot) -> Void)?
    var onReachability: (@Sendable (Bool) -> Void)?

    private let link = WCSession.default

    func start() {
        link.delegate = self
        link.activate()
    }

    var isReachable: Bool { link.isReachable }

    /// True when the phone confirmed the Mac took the answer. The phone is woken in the background by the message.
    func send(_ answer: WatchAnswer) async -> Bool {
        guard link.activationState == .activated, link.isReachable else { return false }
        return await withCheckedContinuation { continuation in
            link.sendMessage(answer.message, replyHandler: { reply in
                continuation.resume(returning: WatchAnswerReply.isDelivered(reply))
            }, errorHandler: { _ in
                continuation.resume(returning: false)
            })
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        onReachability?(session.isReachable)
        if let snapshot = WatchApprovalSnapshot(context: session.receivedApplicationContext) { onSnapshot?(snapshot) }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        onReachability?(session.isReachable)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let snapshot = WatchApprovalSnapshot(context: applicationContext) { onSnapshot?(snapshot) }
    }
}
