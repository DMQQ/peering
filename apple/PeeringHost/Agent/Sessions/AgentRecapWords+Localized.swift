import Foundation
import PeeringKit

extension AgentRecapWords {
    /// Composed on the Mac and shown by the phone as written, so it follows the Mac's language.
    static var localized: AgentRecapWords {
        AgentRecapWords(
            changedFiles: { String(localized: "Changed \($0) files") },
            testsPassed: String(localized: "tests passed"),
            testsFailed: String(localized: "tests failed"),
            waitingToPush: String(localized: "waiting to push"),
            join: { AgentRecapWords.sentence($0) }
        )
    }
}
