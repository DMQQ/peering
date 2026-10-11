import MacCastKit
import StoreKit
import SwiftUI

extension PaywallView {
    enum Reason {
        case quotaExhausted
        case upgrade
        case firstSession
        case runningLow(remaining: TimeInterval)

        var analyticsName: String {
            switch self {
            case .quotaExhausted: "quota_exhausted"
            case .upgrade: "upgrade"
            case .firstSession: "first_session"
            case .runningLow: "running_low"
            }
        }

        var title: String {
            switch self {
            case .quotaExhausted: return String(localized: "Keep going from anywhere")
            case .upgrade: return String(localized: "Connect from anywhere")
            case .firstSession: return String(localized: "Take it with you")
            case .runningLow: return String(localized: "Running low on relay time")
            }
        }

        func detail(for plan: RelayPlan) -> String {
            switch self {
            case .quotaExhausted:
                switch plan {
                case .free:
                    return String(localized: "Your free relay time for today is used up. Upgrade to connect from anywhere without limits.")
                case .relay, .pro:
                    // Unreachable as the app is wired: paid plans are unlimited and never metered,
                    // so the relay cannot refuse one for quota. True rather than blank.
                    return String(localized: "The relay counted this connection against a quota your plan does not have. Try again, and tell us if it keeps happening.")
                }
            case .upgrade:
                return String(localized: "Reaching a Mac away from your own network is metered. Free includes \(RelayPlan.free.allowanceSpelling) a day. Pro removes the limit.")
            case .firstSession:
                let moment = String(localized: "That was your first session. Relay is the part of Peering that reaches your Mac when this device is not on the same network.")
                switch plan {
                case .free:
                    return String(localized: "\(moment) Free includes \(RelayPlan.free.allowanceSpelling) of relay a day. Pro removes the limit.")
                case .relay:
                    return String(localized: "\(moment) You are already subscribed, so there was no meter on this one.")
                case .pro:
                    return String(localized: "\(moment) Your plan already includes unlimited relay, so there is nothing here to buy.")
                }
            case .runningLow(let remaining):
                let left = RelayTime.label(remaining)
                switch plan {
                case .free:
                    return String(localized: "\(left) left today. When it runs out, reaching a Mac on another network stops until the allowance comes back. Pro removes the limit.")
                case .relay, .pro:
                    // Unreachable as the app is wired: paid plans are unlimited, so
                    // ``SessionModel/relaySecondsRemainingEstimate`` is `nil` for them and nothing
                    // can construct this reason. True rather than blank.
                    return String(localized: "\(left) left of today's relay time.")
                }
            }
        }
    }
}
