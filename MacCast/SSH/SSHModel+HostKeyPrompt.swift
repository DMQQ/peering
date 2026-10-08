import Foundation
import MacCastKit
import Observation
import RemoteCore
import SSHCore

extension SSHModel {
    /// Called from the transport, so it hops to the main actor to show a sheet and waits; the `Task` makes the hop legal from a non-isolated `@Sendable` closure.
    func ask(about prompt: SSHHostKeyPrompt) async -> Bool {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.keyAnswer = continuation
                self.keyPrompt = SSHKeyPrompt(prompt: prompt)
            }
        }
    }

    func answerKeyPrompt(_ accepted: Bool) {
        keyPrompt = nil
        keyAnswer?.resume(returning: accepted)
        keyAnswer = nil
    }

    static func describe(_ error: SSHSessionError) -> String {
        switch error {
        case .hostKeyRejected:
            return String(localized: "You did not accept this server's key.")
        case .hostKeyChanged:
            return String(localized: "The server's key has changed since you last connected. If this was not you, do not continue.")
        case .transport(let reason):
            return reason
        case .notConnected:
            return String(localized: "The connection ended.")
        // A browse that failed is reported where it happened (see `browseMessage(_:)`).
        case .browse(let reason):
            return reason
        // Nor is a forward that failed: its sentence belongs on the forward's row. This case only keeps the switch exhaustive as the error type grows.
        case .forward(let reason):
            return SSHForwarder.describe(reason)
        }
    }
}
