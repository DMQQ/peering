import MacCastKit
import StoreKit
import SwiftUI

extension PaywallView {
    enum Reason {
        case quotaExhausted
        case upgrade
        case firstSession
        case runningLow(remaining: TimeInterval)
        case feature(PlanCapability)

        var analyticsName: String {
            switch self {
            case .quotaExhausted: "quota_exhausted"
            case .upgrade: "upgrade"
            case .firstSession: "first_session"
            case .runningLow: "running_low"
            case .feature(let capability): "feature_\(capability.rawValue)"
            }
        }

        var title: String {
            switch self {
            case .quotaExhausted: return String(localized: "Keep going from anywhere")
            case .upgrade: return String(localized: "Connect from anywhere")
            case .firstSession: return String(localized: "Take it with you")
            case .runningLow: return String(localized: "Running low on relay time")
            case .feature(let capability): return String(localized: "Unlock \(capability.name)")
            }
        }

        func detail(for plan: RelayPlan) -> String {
            switch self {
            case .feature(let capability):
                let unlocking = capability.minimumPlan
                guard plan < unlocking else {
                    // Unreachable as the app is wired: a gate asks ``PlanAccess``, and a plan that
                    // includes a capability never draws the lock that opens this door. True rather
                    // than blank, like the two other unreachable branches below.
                    return String(localized: "\(Self.whatItIs(capability)) Your plan already includes it.")
                }
                let current = plan == .free ? String(localized: "the free plan") : plan.name
                return String(localized: "\(Self.whatItIs(capability)) It is not in \(current). \(unlocking.name) adds it.")
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
                return String(localized: "Reaching a Mac on another network runs on the relay, which is metered. Free includes \(RelayPlan.free.allowanceSpelling) a day. Any paid plan removes the limit.")
            case .firstSession:
                let moment = String(localized: "That was your first session. Relay is the part of Peering that reaches your Mac when this device is not on the same network.")
                switch plan {
                case .free:
                    return String(localized: "\(moment) Free includes \(RelayPlan.free.allowanceSpelling) of relay a day. Any paid plan removes the limit.")
                case .relay:
                    return String(localized: "\(moment) You are already subscribed, so there was no meter on this one.")
                case .pro:
                    return String(localized: "\(moment) Your plan already includes unlimited relay, so there is nothing here to buy.")
                }
            case .runningLow(let remaining):
                let left = RelayTime.label(remaining)
                switch plan {
                case .free:
                    return String(localized: "\(left) left today. When it runs out, reaching a Mac on another network stops until the allowance comes back. Any paid plan removes the limit.")
                case .relay, .pro:
                    // Unreachable as the app is wired: paid plans are unlimited, so
                    // ``SessionModel/relaySecondsRemainingEstimate`` is `nil` for them and nothing
                    // can construct this reason. True rather than blank.
                    return String(localized: "\(left) left of today's relay time.")
                }
            }
        }

        private static func whatItIs(_ capability: PlanCapability) -> String {
            switch capability {
            case .extraMacs:
                return String(localized: "Free pairs with one Mac. This is every Mac after it.")
            case .concurrentSessions:
                return String(localized: "One Mac at a time is free. This keeps them all open, so switching is a tap rather than a reconnection.")
            case .macSound:
                return String(localized: "Whatever the Mac is playing comes out of this device, from the music you left running to the alert it makes in answer to a key you sent it.")
            case .pictureInPicture:
                return String(localized: "The Mac's screen floats over your other apps, and iOS floats it by itself when you leave.")
            case .clipboardHistory:
                return String(localized: "The last twenty-five things that crossed between the two, still there when you think of them. Copying and pasting are on every plan.")
            case .mosaic:
                return String(localized: "Pick several of the Mac's windows and see them together, arranged the way you want on this screen. Every tile is captured separately on the Mac, so the picture stays live rather than being a screenshot, and tapping one takes you into it.")
            case .virtualDisplays:
                return String(localized: "A screen the Mac does not physically have, made from this phone and looked at from it: somewhere else for its windows to go, named and taken away from the same list.")
            case .terminalAlerts:
                return String(localized: "A banner when a shell on the Mac or on one of your servers stops and waits for you, on this device while it is open and through the Mac when it is not. The terminal and its own attention mark are on every plan.")
            case .fileTransfer:
                return String(localized: "Takes what you are looking at off a machine and hands it to Files or the share sheet, and puts a file from the phone into the folder you are looking at, up to 2 GB.")
            case .moreAgents:
                return String(localized: "Three agent chats can be open at once on every plan. A fourth needs Relay. Closing a chat makes room for another.")
            case .shellTabs:
                return String(localized: "One shell at a time is free, on your Mac and on any server. This is naming tabs and keeping several open.")
            case .macros:
                return String(localized: "Save a sequence and fire it with a tap. The commands you type most wait as chips above the terminal keyboard, in every shell.")
            case .highBitrate:
                return String(localized: "A sharper picture when the session is relayed. On your own network it is already uncapped on every plan.")
            }
        }
    }
}
