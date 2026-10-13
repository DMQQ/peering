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
nonisolated struct SessionActivityAttributes: ActivityAttributes {
    typealias ContentState = SessionActivityState
    typealias Path = SessionActivityState.Path
    typealias Phase = SessionActivityState.Phase
}
