import Foundation
import PeeringKit

/// The sentences of the spending guard and the five-hour warning.
enum AgentGuardText {
    static func limitTitle(_ warning: AgentLimitWarning) -> String {
        String(localized: "\(warning.percent)% of the five-hour limit used")
    }

    static func limitBody(_ warning: AgentLimitWarning) -> String {
        guard let resetsAt = warning.resetsAt else {
            return String(localized: "Your agents may stop until the limit resets.")
        }
        let time = resetsAt.formatted(date: .omitted, time: .shortened)
        return String(localized: "Your agents may stop until it resets at \(time).")
    }

    static func overrun(_ overrun: AgentSpendingGuard.Overrun) -> String {
        switch overrun {
        case .cost(let spent, let cap):
            let format = FloatingPointFormatStyle<Double>.Currency(code: "USD")
            return String(localized: "This chat has spent \(spent.formatted(format)), past its cap of \(cap.formatted(format)).")
        case .context(let percent, let cap):
            return String(localized: "This chat's context is \(percent)% full, past its cap of \(cap)%.")
        }
    }
}
