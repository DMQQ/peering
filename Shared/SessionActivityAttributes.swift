import ActivityKit
import Foundation

/// The store both the app and the widget extension can see.
///
/// An App Group, because there is no other way across: a widget runs in its own container, so
/// `UserDefaults.standard` inside it is the extension's own store and never the app's. A URL
/// cannot carry it either — a widget's tap is the only thing that crosses, and it goes one way,
/// into the app.
///
/// This sits in the file the two targets already share rather than in one of its own. It is not
/// an ActivityKit type and has no business being in a file that is — but a second shared file
/// means a second round of adding it to both targets by hand, and that cost gets paid again by
/// whoever next wonders why a preference is not reaching the widget.
/// `nonisolated`, because its readers are not on the main actor. The app writes it from views, but
/// Siri and Shortcuts read it from `EntityQuery` methods that AppIntents runs off the main actor,
/// and the widget reads it from a process with no main actor of this app's at all. Under this
/// target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` every one of these statics would otherwise
/// be main-actor isolated, which is a claim none of them can honour.
nonisolated enum SharedStore {
    static let suiteName = "group.pl.dmq.peering"

    /// `nonisolated(unsafe)` on the one stored property here, and it is the only one that needs it.
    /// `UserDefaults` is not `Sendable` as far as the compiler is concerned, but it is documented as
    /// thread-safe, and this value is a `let` bound once at first use.
    private nonisolated(unsafe) static let defaults = UserDefaults(suiteName: suiteName)

    /// The Mac the app last *looked at*, so the widget has something to name.
    ///
    /// **Last looked at rather than last connected to**, which is the same thing until there is
    /// more than one Mac open and stops being it the moment there is. A user who connected to
    /// Studio this morning and has been working on Attic since would find the widget's small tile
    /// offering them Studio, which is the Mac they are least likely to want. It is written from
    /// the connect, from the handshake, and from every switch — see
    /// ``SessionModel/activateSession(_:)``.
    static var lastHostName: String? {
        get { defaults?.string(forKey: "lastHostName") }
        set { defaults?.set(newValue, forKey: "lastHostName") }
    }

    /// The Macs that are open right now, so the widget can mark them.
    ///
    /// Empty when nothing is connected, which is the state the widget drew before this existed:
    /// a list of paired Macs and one of them named as the last used. What it adds is the
    /// difference between "you have paired this" and "you are connected to this", which is the
    /// question somebody glancing at a home screen is actually asking.
    static var connectedMacIDs: [String] {
        get { defaults?.stringArray(forKey: "connectedMacIDs") ?? [] }
        set { defaults?.set(newValue, forKey: "connectedMacIDs") }
    }

    /// Which of them the app is showing.
    ///
    /// `nil` with Macs open is a real state rather than a missing value: the app is between
    /// sessions, or the Mac it was showing has just ended. The widget draws no mark for it.
    static var activeMacID: String? {
        get { defaults?.string(forKey: "activeMacID") }
        set { defaults?.set(newValue, forKey: "activeMacID") }
    }

    /// One Mac the phone knows about, as the widget needs it: enough to name it and enough to
    /// ask for it back.
    ///
    /// A copy of the app's own list rather than a reference to it, because there is no shared
    /// store between the two processes beyond this one — see the note above. Written by the app
    /// whenever its pairings or their names change.
    struct KnownMac: Codable, Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// The Macs this phone has paired with, most recently used first.
    ///
    /// Order matters: the widget only has room for a few, and the ones to show are the ones most
    /// likely to be wanted. The app writes it in its own order and the widget takes it as given.
    static var knownMacs: [KnownMac] {
        get {
            guard let data = defaults?.data(forKey: "knownMacs") else { return [] }
            return (try? JSONDecoder().decode([KnownMac].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults?.set(data, forKey: "knownMacs")
        }
    }

    /// One SSH server the phone knows about.
    ///
    /// Mirrored for two reasons rather than one. `KnownMac` is here because the widget's process
    /// cannot read the app's `UserDefaults`; this is here for that *and* for Siri, which resolves
    /// "open a shell on prod" into a server at moments when the app is not running. An entity
    /// query that could only see the app's own defaults would offer an empty list, and a
    /// parameter with nothing to choose from is a phrase Siri simply refuses.
    ///
    /// Strings, not `SSHHost`: this file is compiled into the widget too, which does not link
    /// `SSHCore` and has no use for a port number.
    struct KnownServer: Codable, Identifiable, Hashable {
        let id: String
        let name: String
        /// `user@host:port`, which is what tells two servers on one box apart.
        let detail: String
    }

    /// The saved servers, in the order the app's list shows them — most recently used first.
    static var knownServers: [KnownServer] {
        get {
            guard let data = defaults?.data(forKey: "knownServers") else { return [] }
            return (try? JSONDecoder().decode([KnownServer].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults?.set(data, forKey: "knownServers")
        }
    }
}

/// The Live Activity's shape, compiled into **both** the app and the widget extension.
///
/// One file, two targets, deliberately. ActivityKit decodes the state the app wrote using the
/// widget's `ActivityConfiguration(for:)`, and the two agree only because they are literally
/// the same `Codable` declaration. A second copy in the widget folder would compile, link, and
/// then render nothing at all — an activity that never appears is not an error anywhere, which
/// makes it the most expensive kind of mistake to find.
///
/// There is deliberately no free-text `detail` field. The obvious thing to put in one is the
/// session's status string, and that string is written for the diagnostics panel — it reads
/// "H264 1800×1168 · 282 frames · 22 dropped". A Lock Screen is not a log viewer, and a field
/// that invites that is a field that will eventually be filled with it.
/// `nonisolated`, for the reason the paragraph above gives from the other direction. ActivityKit
/// encodes the app's state and decodes it in the widget, and it does both from a `@concurrent`
/// context. A conformance isolated to the main actor cannot be used there, and the failure is not
/// one this file could recover from, so the type opts out of the default isolation entirely. It is
/// plain `Codable` data with no state to protect, which is what makes that free.
nonisolated struct SessionActivityAttributes: ActivityAttributes {
    /// Everything the Lock Screen is allowed to change. Fixed at request time and never
    /// updated, so nothing that varies may live in the properties above.
    struct ContentState: Codable, Hashable {
        var phase: Phase

        /// Nil until video is flowing. `Text(startedAt, style: .timer)` renders the running
        /// duration from it and the *system* advances that clock, which is the only reason the
        /// timer stays right on a Lock Screen where none of this app is running.
        var startedAt: Date?

        /// How this session is being carried. Nil until the handshake has decided.
        ///
        /// The three are not equivalent and the difference is invisible in the picture: `lan`
        /// crosses the local network, `relay` has gone out to a server and back, and `direct`
        /// is an address typed by hand. When a session feels slow this is the first question
        /// anyone asks, and the Lock Screen is where they are looking when they ask it.
        var path: Path?

        /// The name of the Mac this card is about.
        ///
        /// **Here rather than among the attributes above, and that is what lets the card follow a
        /// tab.** `ActivityAttributes` are fixed when the activity is requested and there is no
        /// API to change them afterwards; only `ContentState` updates. A name living up there
        /// could only ever be the name of the Mac the card was started for, so switching to
        /// another Mac would leave the Lock Screen naming one the user is not looking at, and the
        /// only way to correct it would be to end the card and start a second one — which throws
        /// away the running clock that makes the card worth having.
        ///
        /// Optional so that a card started by an earlier build still decodes: a missing field
        /// reads as absent rather than throwing, and a Live Activity that fails to decode is a
        /// card that vanishes mid-session. The views fall back to the app's own name.
        var hostName: String?

        /// How many Macs are open, so the card can say when there is more than one.
        ///
        /// A count rather than the names: the Lock Screen has room for one line, and the useful
        /// fact there is not which other Macs are open but that the connection being described is
        /// one of several. Optional for the same decoding reason as the name.
        var sessionCount: Int?
    }

    /// The transport behind a session, as a word short enough for a chip.
    enum Path: String, Codable, Hashable, Sendable {
        case lan = "LAN"
        case relay = "Relay"
        case direct = "Direct"

        /// The same fact inside a sentence: "Connected via LAN", "Connected directly".
        ///
        /// The raw value is the wire format and cannot follow the sentence it lands in, since a
        /// stored activity decodes through it. "Connected via Direct" is what using it as one
        /// gives.
        var phrase: String {
            switch self {
            case .lan: return "via LAN"
            case .relay: return "via Relay"
            case .direct: return "directly"
            }
        }
    }

    /// A session, reduced to what a Lock Screen has room to say.
    ///
    /// Connecting, handshaking and awaiting the pairing code are one case rather than three:
    /// the Lock Screen has nothing different to say about them, and three cases would be three
    /// identical layouts waiting to disagree.
    enum Phase: String, Codable, Hashable {
        case pending
        case active
        /// The session dropped and the app is putting it back on its own.
        ///
        /// Its own case rather than a return to `pending`, because it is a different promise: a
        /// pending card says "a session is coming", and this one has to say that one *did* exist
        /// and was lost. Going back to the hourglass would make a drop look like a first attempt.
        case reconnecting

        /// The session is over and is not coming back on its own.
        ///
        /// Its own case rather than taking the card down, which is what used to happen and is
        /// the wrong answer twice over. A card that vanishes says nothing: the user was
        /// watching a Mac a second ago and now there is no card at all, so the drop is
        /// indistinguishable from having quit. And the one thing that helps — offering to put
        /// it back — is exactly what a removed card cannot do.
        case dropped
    }
}
