import Foundation
import MacCastKit
import RemoteCore
import os

/// The failure events. Each is a closed stage and reason plus a number, built in ``PhoneFailure``: never an error sentence, a name, an address or a path.
extension Analytics {
    private static func report(_ event: PhoneFailure.Event, _ properties: [String: any Sendable]) {
        send(event.rawValue, properties)
    }

    static func pairingFailed(stage: PhoneFailure.PairingStage, reason: String, sessionRef: String? = nil) {
        report(.pairing, PhoneFailure.properties(stage: stage.rawValue, reason: reason, code: nil, extra: sessionRef.map { ["session_ref": $0] } ?? [:]))
    }

    static func pairingInputRefused(_ problem: PairingPayloadError, stage: PhoneFailure.PairingStage) {
        pairingFailed(stage: stage, reason: PhoneFailure.pairingReason(problem))
    }

    static func fileTransferFailed(_ error: Error, direction: PhoneFailure.TransferDirection, stage: PhoneFailure.TransferStage, bytes: Int64?) {
        report(.fileTransfer, PhoneFailure.transferProperties(direction: direction, stage: stage, error: error, bytes: bytes))
    }

    static func sshFailed(_ error: Error, afterConnected: Bool) {
        let failure = PhoneFailure.sshFailure(error, after: afterConnected)
        report(.ssh, PhoneFailure.properties(stage: failure.stage.rawValue, reason: failure.reason, code: failure.code))
    }

    /// The Mac's own sentence is free text, so only the stage and the fact that the Mac reported it are sent.
    static func terminalFailed(stage: PhoneFailure.TerminalStage) {
        report(.terminal, PhoneFailure.properties(stage: stage.rawValue, reason: PhoneFailure.Cause.hostReported.rawValue, code: nil))
    }

    static func agentFailed(stage: PhoneFailure.AgentStage, cause: PhoneFailure.Cause = .hostReported) {
        report(.agent, PhoneFailure.agentProperties(stage: stage, cause: cause))
    }

    static func pushRegistrationFailed(_ error: Error) {
        let failure = PhoneFailure.pushReason(error)
        report(.pushRegistration, PhoneFailure.properties(stage: nil, reason: failure.reason, code: failure.code))
    }

    static func purchaseFailed(_ error: Error, product: String) {
        let nsError = error as NSError
        report(.purchase, PhoneFailure.properties(stage: nil, reason: PhoneFailure.purchaseReason(error), code: nsError.code, extra: ["product": product]))
    }

    static func receiptVerificationFailed(_ error: Error, product: String?) {
        report(.receiptVerification, PhoneFailure.properties(stage: nil, reason: PhoneFailure.receiptReason(error), code: nil, extra: ["product": product ?? "unknown"]))
    }

    private static let pinStoreReported = OSAllocatedUnfairLock(initialState: false)

    /// Once per launch: the store is read on every connect, and an unreadable one stays unreadable.
    static func pinStoreUnreadable(status: Int32?) {
        guard !pinStoreReported.withLock({ let was = $0; $0 = true; return was }) else { return }
        report(.pinStoreUnreadable, PhoneFailure.pinStoreProperties(status: status))
    }
}
