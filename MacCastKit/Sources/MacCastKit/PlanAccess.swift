import Foundation

/// One thing the app does that not every plan includes, and the cheapest plan that includes it.
///
/// **This is the map, and it is the only copy of it.** The paywall's cards, the "Everything
/// included" list, the badges on its rows and the lock on every gated control all ask this type
/// rather than restating it, because the four of them are one or two taps apart and a feature that
/// is paid on one screen and free on the next is not a difference of opinion, it is the app
/// contradicting itself on the way to a purchase. `PLANS-AND-FEATURES.md` and `Relay/site` state
/// the same map in prose, and they are the two that cannot be compiled against it: a change here
/// is a change owed to both of them in the same commit.
///
/// **Seven rows, and everything else in the app is free.** Every display, app and window as a
/// source, the desktops panel, the clipboard and its history, the pointer and the keyboard, observe
/// mode, screenshots, privacy mode, widgets, the Live Activity, Siri and Shortcuts, notifications,
/// session history, wake on LAN, saving SSH servers, one Mac at a time, one shell at a time and the
/// whole file browser including editing, making, renaming, deleting and running what it lists. None
/// of those are here, and none of them should be. A capability that is not on this list cannot be
/// gated by accident, because the question a gate asks is this type and there is no case for it.
///
/// **SSH servers were a seventh and were removed.** The gate said the app was holding the user's own
/// saved machines behind a subscription: a host they typed in themselves, kept in their keychain
/// and named by them, drawn back to them with a padlock at the end of the row. What a plan buys in
/// a terminal is the *concurrency*, not the capability, and the row that does that work is
/// ``shellTabs`` on its own: free runs one shell at a time on a Mac and on a server alike, and the
/// second one at the same time is what costs. Removing the case rather than moving it to `free` is
/// deliberate: a capability the free plan includes is a capability some later edit can put a badge
/// on again, and the absence of a case is the only version of "this is not for sale" that the
/// compiler holds the app to.
public enum PlanCapability: String, CaseIterable, Sendable {
    /// A second Mac, and every one after it. Free pairs with one.
    ///
    /// The only capability here that is not a control or a surface: it is a limit on a list. It
    /// costs the service nothing to serve, which is why it sits on the cheapest rung rather than
    /// being sold back at each one. See the note on the Mac count in the app's `Tier`.
    case extraMacs

    /// A second Mac held open at the same time as the first.
    ///
    /// **A concurrency gate rather than a capability gate**, which is the same axis as ``shellTabs``
    /// and the same argument that took SSH servers out of this map: nothing is hidden by it. The
    /// first Mac is free on every plan, its picture, its shells, its files and its clipboard are all
    /// free, and what a plan buys is the second one being *open at the same moment* rather than
    /// reached by ending the first.
    ///
    /// It belongs beside ``extraMacs`` and is deliberately separate from it. That one is a limit on
    /// a list — how many Macs may be paired — and this one is a limit on how many may be live. A
    /// subscriber on Relay pairs every Mac they own and holds one at a time, which is what the card
    /// for that rung says.
    ///
    /// It costs the service real money, more than anything else here: every session held open is a
    /// control connection the relay goes on splicing whether or not the user is looking at it, and
    /// the picture of the Mac that is on screen is joined by the sleep assertion, the keepalive and
    /// the metering of each one behind it. That is what puts it on Pro rather than on the entry
    /// rung, where a limit on pairing sits.
    case concurrentSessions
    case macSound
    case pictureInPicture
    /// Moving a file between the phone and the machine, in either direction: taking one off it, and
    /// sending one to it. One capability rather than two, because they are one gesture with the
    /// arrow reversed and a plan that allowed one of them would be a plan nobody could describe.
    case fileTransfer
    case shellTabs
    /// Macros, the snippets above the terminal keyboard, and the quick commands in a shell.
    ///
    /// One capability rather than three, because they are one idea at three sizes (a saved thing
    /// you fire with a tap instead of typing it), and the card that sells them has always said them
    /// in one line.
    case macros
    /// How sharp the picture may get on a relayed session.
    ///
    /// **The one gate in this map about how much rather than whether.** Every other capability here
    /// is a control or a surface that exists or does not exist; this is the ceiling the rate is
    /// allowed to climb to, and every plan still gets a picture, still adapts to the network, and
    /// still reaches the top rate when the two devices are on the same network. What a plan decides
    /// is how far it may climb when the bytes are being carried.
    ///
    /// It costs the service real money in a way nothing else here does. A relayed stream at 20 Mbps
    /// is five times the bandwidth of the same session held at 8, and it is the operator's link
    /// either way, which is the whole argument for selling it rather than giving it away. It is
    /// also the shape the field uses at the top of the ladder: Jump caps its free plan at 20 Mbps
    /// against 60 for its enterprise tier, and Splashtop puts 4:4:4 and 240 fps in Performance.
    ///
    /// Deliberately not a ceiling on the direct path. Two devices on one network are not costing
    /// anybody anything, so capping them would be charging for a picture the user is already
    /// paying for with their own hardware, and it would degrade the one demonstration of this app
    /// that most people see first.
    case highBitrate

    /// The cheapest plan that includes this, which is the whole of the map.
    ///
    /// A `RelayPlan` rather than a `StoreManager.Tier`, and deliberately: the tiers are what the
    /// App Store sells, the plans are what the array of features is, and a fourth product that
    /// resold the same plan would change the ladder without changing a single answer here.
    public var minimumPlan: RelayPlan {
        switch self {
        case .extraMacs, .macSound, .pictureInPicture, .fileTransfer:
            // The remote working set: away from your own network, with every Mac you own, its
            // sound, its picture floating over another app, and files that move both ways. The
            // entry rung used to differ from free in exactly one number, three hours against half
            // an hour, which made it the hardest thing on the ladder to sell. See the note in
            // `PLANS-AND-FEATURES.md` on why these four moved down to it.
            return .relay
        case .shellTabs:
            // The clock going away, and the concurrency with it. Terminals are the one row that
            // goes against the direction of travel in the terminal category, where tabs are free
            // at every competitor worth naming: the compromise is that one shell is free and only
            // the second one costs, which reads as fair where hiding the terminal would read as
            // stingy. This is the row that had to carry that on its own once SSH servers left the
            // map, and it was always the half of the pair doing the arguing.
            return .plus
        case .concurrentSessions:
            // The only row here that is about how many of something may be live at once, and the
            // only one whose cost scales with the number rather than with the user. It is the
            // second Mac that costs and the first that must not, which is why the gate is asked
            // against an empty list as well as a paid plan.
            return .pro
        case .macros, .highBitrate:
            // The toolbox. Macros are the only genuinely power-user controls in the app, and the
            // rung somebody buys to have the tool rather than to run out of it. The picture's
            // ceiling is here for a different reason and belongs beside them anyway: it is the one
            // thing in the map that costs the service money every time it is used, so it is the one
            // thing that has to be paid for by the people who use it most.
            return .pro
        }
    }

    /// The feature's own name, in the words the user will find on the screen they were using.
    ///
    /// Written for a sentence rather than for a row: every gate that is refused says what it
    /// refused by name, so the user reads "Sound from the Mac is part of Relay" rather than a
    /// purchase screen that has appeared out of nowhere with nothing to connect it to the control
    /// under their thumb. The wording follows the cards for the same reason the card and the row
    /// follow each other: the badge saying one thing and the lock another is the drift this whole
    /// arrangement exists to prevent.
    public var name: String {
        switch self {
        case .extraMacs: return "Pairing another Mac"
        case .concurrentSessions: return "Several Macs at once"
        case .macSound: return "Sound from the Mac"
        case .pictureInPicture: return "Picture in Picture"
        case .fileTransfer: return "Moving files between the phone and the Mac"
        case .shellTabs: return "Several shells at once"
        case .macros: return "Macros, snippets and quick commands"
        case .highBitrate: return "The sharpest picture"
        }
    }
}

/// What the user's plan includes, or the fact that the app does not know yet.
///
/// **The third state is the point, and it is not a default.** The plan is read from StoreKit's
/// `Transaction.currentEntitlements`, which is a local call and answers offline, but it is still
/// an `await`, so for the first moments of every launch there is no answer, and code that treated
/// "no answer" as "free" would lock a paying subscriber out of the app they paid for, on every
/// launch, for a moment. That is not a hypothetical: it is what a `Bool` read from
/// `activeTier != nil` does, and it is the flash the owner's rule is about.
///
/// **So an unanswered plan locks nothing.** ``includes(_:)`` answers `true` while the state is
/// ``unknown``, which is the safe direction rather than the generous one: the window is a single
/// local StoreKit call, a free user who spent it tapping a paid control would have to beat the
/// first frame, and the cost of being wrong the other way is a subscriber looking at a badge beside
/// a feature they are paying for. What must never happen is the second one.
///
/// **Read the entitlement, never the price list.** `StoreManager.products` is a network fetch and
/// can be empty on a plane, before App Store Connect has the products, or on the simulator without
/// a StoreKit configuration. Nothing here may be derived from it: an entitlement is what has been
/// paid for, a product is what is for sale, and the two are answered by different services at
/// different speeds.
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
}
