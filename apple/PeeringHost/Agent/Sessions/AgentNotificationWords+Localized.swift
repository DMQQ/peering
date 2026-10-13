import Foundation
import MacCastKit
import RemoteCore

extension AgentNotificationWords {
    /// A push is composed here and shown by the phone as written, so it follows the Mac's language.
    static var localized: AgentNotificationWords {
        AgentNotificationWords(
            asks: { String(localized: "\($0) asks") },
            needsApproval: String(localized: "Needs your approval."),
            title: { name, outcome in
                switch outcome {
                case .finished: String(localized: "\(name) finished")
                case .stopped: String(localized: "\(name) stopped")
                case .failed: String(localized: "\(name) failed")
                }
            },
            turn: { outcome in
                switch outcome {
                case .finished: String(localized: "The turn finished.")
                case .stopped: String(localized: "The turn was stopped.")
                case .failed: String(localized: "The turn failed.")
                }
            },
            filesChanged: { String(localized: "\($0) files changed") },
            duration: { TerminalCommandFinishDetector.spokenDuration($0) },
            claudeCode: "Claude Code",
            claudeCodeIn: { String(localized: "Claude Code in \($0)") },
            claudeCodeWaiting: String(localized: "Claude Code is waiting for you.")
        )
    }
}
