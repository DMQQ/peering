import Foundation

/// One thing the app does that not every plan includes, and the cheapest plan that includes it.
public enum PlanCapability: String, CaseIterable, Sendable {
    /// A second Mac, and every one after it. Free pairs with one.
    ///
    /// A limit on a list rather than a control or a surface.
    case extraMacs

    /// A second Mac held open at the same time as the first.
    case concurrentSessions
    case macSound
    case pictureInPicture
    /// Moving a file between the phone and the machine, in either direction: taking one off it, and
    /// sending one to it. One capability rather than two, because a plan that allowed only one
    /// direction would be a plan nobody could describe.
    case fileTransfer

    case clipboardHistory

    /// The Mac telling the phone that a terminal has stopped and is waiting for a person.
    case terminalAlerts

    case shellTabs
    /// Macros, the snippets above the terminal keyboard, and the quick commands in a shell.
    case macros
    case highBitrate

    /// Several of the Mac's windows drawn into one picture, arranged by the user.
    case mosaic

    /// The virtual displays this phone makes: adding one, naming it, taking it away, and looking at
    /// it.
    case virtualDisplays

    /// A chat with a coding agent on the Mac: the native screen, rather than the agent's own
    /// terminal UI.
    case agentChat

    public var minimumPlan: RelayPlan {
        switch self {
        case .extraMacs, .macSound, .pictureInPicture, .fileTransfer, .clipboardHistory,
             .terminalAlerts:
            return .relay
        case .concurrentSessions:
            // The second Mac costs and the first must not, which is why the gate is asked against
            // an empty list as well as a paid plan.
            return .pro
        case .shellTabs, .virtualDisplays, .macros, .highBitrate, .mosaic, .agentChat:
            // The toolbox: the rung somebody buys to have the tool rather than to run out of it.
            // One shell is free and only the second costs; a display the Mac does not physically
            // have is the same shape of ask.
            return .pro
        }
    }

    public var name: String {
        switch self {
        case .extraMacs: return String(localized: "Pairing another Mac")
        case .concurrentSessions: return String(localized: "Several Macs at once")
        case .macSound: return String(localized: "Sound from the Mac")
        case .pictureInPicture: return String(localized: "Picture in Picture")
        case .fileTransfer: return String(localized: "Moving files between the phone and the Mac")
        case .clipboardHistory: return String(localized: "The clipboard history")
        case .terminalAlerts: return String(localized: "Knowing when a terminal needs you")
        case .mosaic: return String(localized: "Several windows at once")
        case .virtualDisplays: return String(localized: "Virtual displays on the phone")
        case .shellTabs: return String(localized: "Several shells at once")
        case .macros: return String(localized: "Macros, snippets and quick commands")
        case .highBitrate: return String(localized: "The sharpest picture")
        case .agentChat: return String(localized: "Chat with your coding agents")
        }
    }
}

/// What the user's plan includes, or the fact that the app does not know yet.
public enum PlanAccess: Sendable, Equatable {
    /// The App Store has not answered yet. Locks nothing; see the note above.
    case unknown
    case known(RelayPlan)

    public func includes(_ capability: PlanCapability) -> Bool {
        switch self {
        case .unknown:
            return true
        case .known(let plan):
            return plan.includes(capability)
        }
    }

    public var plan: RelayPlan? {
        switch self {
        case .unknown: return nil
        case .known(let plan): return plan
        }
    }

    /// Whether the Sessions screen has a relay allowance to show.
    public var showsRelayAllowance: Bool {
        self == .known(.free)
    }
}
