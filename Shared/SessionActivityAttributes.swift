import ActivityKit
import Foundation

/// An App Group: a widget runs in its own container, so `UserDefaults.standard` there is never the app's store.
/// `nonisolated`: Siri and Shortcuts read it off the main actor and the widget has no main actor of this app's, but the target defaults to `MainActor`.
nonisolated enum SharedStore {
    static let suiteName = "group.pl.dmq.peering"

    /// `UserDefaults` is not `Sendable` to the compiler but is documented thread-safe, and this is a `let` bound once.
    private nonisolated(unsafe) static let defaults = UserDefaults(suiteName: suiteName)

    /// The Mac the app last looked at (not last connected to, which differs with several Macs open), so the widget has something to name.
    static var lastHostName: String? {
        get { defaults?.string(forKey: "lastHostName") }
        set { defaults?.set(newValue, forKey: "lastHostName") }
    }

    /// The Macs that are open right now, so the widget can mark them.
    static var connectedMacIDs: [String] {
        get { defaults?.stringArray(forKey: "connectedMacIDs") ?? [] }
        set { defaults?.set(newValue, forKey: "connectedMacIDs") }
    }

    /// `nil` with Macs open is a real state (between sessions); the widget draws no mark.
    static var activeMacID: String? {
        get { defaults?.string(forKey: "activeMacID") }
        set { defaults?.set(newValue, forKey: "activeMacID") }
    }

    /// One Mac the phone knows about, as the widget needs it. A copy of the app's list, since no other store is shared between the processes.
    struct KnownMac: Codable, Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// Paired Macs, most recently used first; the widget only has room for a few and takes the order as given.
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

    /// The agent chats the phone holds, as the Agents widget and its Live Activity draw them. Written by the app, a few times a second at most.
    static var agentChats: [AgentChatSnapshot] {
        get {
            guard let data = defaults?.data(forKey: "agentChats") else { return [] }
            return (try? JSONDecoder().decode([AgentChatSnapshot].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults?.set(data, forKey: "agentChats")
        }
    }

    /// One SSH server the phone knows about, mirrored for the widget and for Siri, which resolves "open a shell on prod" while the app is not running. Strings, not `SSHHost`: the widget does not link `SSHCore`.
    struct KnownServer: Codable, Identifiable, Hashable {
        let id: String
        let name: String
        /// `user@host:port`, which is what tells two servers on one box apart.
        let detail: String
    }

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

/// Compiled into both the app and the widget: ActivityKit decodes the app's state with the widget's `ActivityConfiguration(for:)`, and a second copy would compile and then render nothing.
///
/// There is deliberately no free-text `detail` field: the session status string is written for the diagnostics panel, not a Lock Screen.
/// `nonisolated`: ActivityKit encodes and decodes from a `@concurrent` context, where a main-actor conformance cannot be used.
nonisolated struct SessionActivityAttributes: ActivityAttributes {
    /// Everything the Lock Screen may change; the attributes above are fixed at request time.
    struct ContentState: Codable, Hashable {
        var phase: Phase

        /// Nil until video is flowing; the system advances `Text(startedAt, style: .timer)`, which keeps the clock right on a Lock Screen.
        var startedAt: Date?

        /// How this session is carried: nil until the handshake has decided.
        var path: Path?

        /// The Mac this card is about. It lives in `ContentState` because attributes cannot change after the request, so the card could not follow a tab.
        /// Optional so a card started by an earlier build still decodes; the views fall back to the app's name.
        var hostName: String?

        /// How many Macs are open, so the card can say when there is more than one.
        var sessionCount: Int?

        /// What is running on the Mac. One card lists the work rather than one card per job; what is waiting on the user comes first. Optional so older cards decode.
        var work: [Work]?

        struct Work: Codable, Hashable {
            var name: String
            /// An SF Symbol, chosen on the phone: the widget does not know what a chat is.
            var symbol: String
            var state: State
            var detail: String?

            enum State: String, Codable, Hashable {
                case live
                case waiting
                case failed

                var isWaiting: Bool { self == .waiting }
            }
        }
    }

    enum Path: String, Codable, Hashable, Sendable {
        case lan = "LAN"
        case relay = "Relay"
        case direct = "Direct"
    }

    /// Connecting, handshaking and awaiting the pairing code are one case: the Lock Screen has nothing different to say about them.
    enum Phase: String, Codable, Hashable {
        case pending
        case active
        /// Its own case rather than `pending`: a drop must not look like a first attempt.
        case reconnecting

        /// Its own case rather than removing the card: a vanished card is indistinguishable from quitting and cannot offer to reconnect.
        case dropped
    }
}
