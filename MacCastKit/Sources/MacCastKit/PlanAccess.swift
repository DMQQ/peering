import Foundation

/// One thing the app does that not every plan includes, and the cheapest plan that includes it.
///
/// This is the only copy of the map: the paywall's cards, the "Everything included" list, the
/// badges on its rows and the lock on every gated control all ask this type rather than restating
/// it. `PLANS-AND-FEATURES.md` and `Relay/site` state the same map in prose and cannot be compiled
/// against it, so a change here is owed to both in the same commit.
///
/// Everything not listed here is free on every plan, and a capability with no case cannot be gated
/// by accident: the question a gate asks is this type.
public enum PlanCapability: String, CaseIterable, Sendable {
    /// A second Mac, and every one after it. Free pairs with one.
    ///
    /// A limit on a list rather than a control or a surface.
    case extraMacs

    /// A second Mac held open at the same time as the first.
    ///
    /// A concurrency gate rather than a capability gate, the same axis as ``shellTabs``: nothing is
    /// hidden, and the first Mac with its picture, shells, files and clipboard is free on every
    /// plan. Deliberately separate from ``extraMacs``, which limits how many Macs may be paired
    /// rather than how many may be live.
    ///
    /// It costs the service real money, more than anything else here, which is what puts it on Pro
    /// rather than on the entry rung.
    case concurrentSessions
    case macSound
    case pictureInPicture
    /// Moving a file between the phone and the machine, in either direction: taking one off it, and
    /// sending one to it. One capability rather than two, because a plan that allowed only one
    /// direction would be a plan nobody could describe.
    case fileTransfer

    /// The list of what was copied through the session, rather than the copying of it.
    ///
    /// The same line this app draws through macros: what a plan buys is the shelf, not the ability
    /// to use it. Pull, Copy and Push are on the rail on every plan, and what Relay adds is the
    /// history behind them; gating the rail would be charging for the clipboard.
    case clipboardHistory

    /// The Mac telling the phone that a terminal has stopped and is waiting for a person.
    ///
    /// One capability over two deliveries, because they are one message: while a session is up the
    /// banner is posted by the phone itself, and when no session is up the Mac sends it over the
    /// relay and APNs to the device token the phone handed it on the way in.
    ///
    /// The terminal stays free on every plan; what a plan buys is the reaching of the user, which is
    /// the only part of it the relay and APNs are in the path of, and so the only part that costs
    /// the service anything.
    case terminalAlerts

    case shellTabs
    /// Macros, the snippets above the terminal keyboard, and the quick commands in a shell.
    ///
    /// One capability rather than three, because they are one idea at three sizes: a saved thing you
    /// fire with a tap instead of typing it.
    case macros
    /// How sharp the picture may get on a relayed session.
    ///
    /// The one gate in this map about how much rather than whether. Every plan still gets a picture,
    /// still adapts to the network, and still reaches the top rate when the two devices are on the
    /// same network; what a plan decides is how far the rate may climb while the bytes are being
    /// carried.
    ///
    /// Deliberately not a ceiling on the direct path, where capping would charge for a picture the
    /// user is already paying for with their own hardware.
    case highBitrate

    /// Several of the Mac's windows drawn into one picture, arranged by the user.
    ///
    /// The only row here that costs the Mac rather than the service: every tile is a
    /// ScreenCaptureKit stream of its own, drawn into one canvas and encoded each frame, so the Mac
    /// is asked to work several times as hard. Nothing about it crosses the relay that does not
    /// cross it for one source.
    case mosaic

    /// Making and removing virtual displays from the phone, beyond the one the Mac's own switch
    /// controls.
    ///
    /// The switch itself, and the one display it makes, are free on every plan and stay a local
    /// setting on the Mac; what a plan buys is the phone being able to ask for more of them. The
    /// same rung as ``shellTabs``, not ``mosaic``/``macros``/``highBitrate`` — this is a tool
    /// somebody reaches for the moment they have two Macs' worth of work and one Mac, not a
    /// luxury saved for the top plan.
    case virtualDisplays

    /// The cheapest plan that includes this, which is the whole of the map.
    ///
    /// A `RelayPlan` rather than a `StoreManager.Tier`: the tiers are what the App Store sells and
    /// the plans are what the array of features is.
    public var minimumPlan: RelayPlan {
        switch self {
        case .extraMacs, .macSound, .pictureInPicture, .fileTransfer, .clipboardHistory,
             .terminalAlerts:
            // The remote working set: away from your own network, with every Mac you own, its
            // sound, its picture floating over another app, files that move both ways, and the Mac
            // able to reach you when a shell stops for an answer.
            return .relay
        case .shellTabs, .virtualDisplays:
            // The clock going away, and the concurrency with it: one shell is free and only the
            // second one costs. A second display from the phone is the same shape of ask.
            return .plus
        case .concurrentSessions:
            // The second Mac costs and the first must not, which is why the gate is asked against
            // an empty list as well as a paid plan.
            return .pro
        case .macros, .highBitrate, .mosaic:
            // The toolbox: the rung somebody buys to have the tool rather than to run out of it.
            return .pro
        }
    }

    /// The feature's own name, in the words the user will find on the screen they were using.
    ///
    /// Written for a sentence rather than for a row: every refused gate says what it refused by
    /// name, so the user reads "Sound from the Mac is part of Relay" rather than a purchase screen
    /// with nothing connecting it to the control under their thumb.
    public var name: String {
        switch self {
        case .extraMacs: return "Pairing another Mac"
        case .concurrentSessions: return "Several Macs at once"
        case .macSound: return "Sound from the Mac"
        case .pictureInPicture: return "Picture in Picture"
        case .fileTransfer: return "Moving files between the phone and the Mac"
        case .clipboardHistory: return "The clipboard history"
        case .terminalAlerts: return "Knowing when a terminal needs you"
        case .mosaic: return "Several windows at once"
        case .virtualDisplays: return "Extra virtual displays"
        case .shellTabs: return "Several shells at once"
        case .macros: return "Macros, snippets and quick commands"
        case .highBitrate: return "The sharpest picture"
        }
    }
}

/// What the user's plan includes, or the fact that the app does not know yet.
///
/// The third state is the point. The plan comes from StoreKit's `Transaction.currentEntitlements`,
/// which answers offline but is still an `await`, so there are moments after every launch with no
/// answer, and treating that as free would flash a lock at a paying subscriber.
///
/// So an unanswered plan locks nothing: ``includes(_:)`` answers `true` while the state is
/// ``unknown``, because a subscriber looking at a badge beside a feature they pay for is the worse
/// error.
///
/// Read the entitlement, never the price list: `StoreManager.products` is a network fetch and can
/// be empty on a plane or before App Store Connect has the products.
public enum PlanAccess: Sendable, Equatable {
    /// The App Store has not answered yet. Locks nothing; see the note above.
    case unknown
    /// The plan the App Store says this Apple Account is entitled to.
    case known(RelayPlan)

    /// Whether the plan includes a feature, and the one question every gate in the app asks.
    public func includes(_ capability: PlanCapability) -> Bool {
        switch self {
        case .unknown:
            return true
        case .known(let plan):
            return plan.includes(capability)
        }
    }

    /// The plan once it is known, or `nil` for the moment before.
    public var plan: RelayPlan? {
        switch self {
        case .unknown: return nil
        case .known(let plan): return plan
        }
    }

    /// Whether the Sessions screen has a relay allowance to show.
    ///
    /// Paid plans are unlimited, so a meter is not useful account information for them, and an
    /// unread entitlement is hidden too: answering the other way would flash a free-plan limit at
    /// every subscriber while StoreKit answers.
    public var showsRelayAllowance: Bool {
        self == .known(.free)
    }
}
