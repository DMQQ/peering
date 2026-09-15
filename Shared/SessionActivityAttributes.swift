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
enum SharedStore {
    static let suiteName = "group.pl.dmq.peering"

    private static let defaults = UserDefaults(suiteName: suiteName)

    /// The Mac the app last connected to, so the widget has something to name.
    static var lastHostName: String? {
        get { defaults?.string(forKey: "lastHostName") }
        set { defaults?.set(newValue, forKey: "lastHostName") }
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
struct SessionActivityAttributes: ActivityAttributes {
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
    }

    /// The transport behind a session, as a word short enough for a chip.
    enum Path: String, Codable, Hashable, Sendable {
        case lan = "LAN"
        case relay = "Relay"
        case direct = "Direct"
    }

    /// The Mac's name, which the session has from the handshake onwards.
    var hostName: String

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
