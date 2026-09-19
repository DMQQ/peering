import AppIntents
import RemoteCore
import SSHCore
import SwiftUI

/// What Siri and Shortcuts can ask Peering to do.
///
/// Two intents, and they are deliberately the two that outlive the app being open: connect to a
/// Mac, and stop. Everything else here — the pointer, the keyboard, the joystick — is a thing
/// done *at* a screen, by hand, and there is no sentence worth saying to a speaker for it.
///
/// Neither can quietly run in the background. A session is a certificate identity and two sockets
/// opened in this process, so an intent that wanted one without the app being open would have
/// nothing to open it with — see ``SessionModel``'s note on why the model is owned by the `App`.
/// `openAppWhenRun` is the honest description of that, not a workaround.

/// The model an intent reaches.
///
/// `SessionModel` is owned by the `App` struct and has no view hierarchy an intent could read it
/// from, so the app hands it over once at launch. Weak, because the app's ownership is the real
/// one: an intent must never be the thing keeping a session alive.
@MainActor
enum IntentHost {
    static weak var model: SessionModel?

    /// The Servers tab's model, handed over for the same reason and kept separate for a different
    /// one: a shell and a remote desktop session are two products sharing an app, and an intent
    /// for one has no business being able to reach the other.
    static weak var servers: SSHModel?
}

/// One of the Macs this phone has paired with.
///
/// Backed by the app-group list rather than the app's own, because Shortcuts asks for the choices
/// — to build the picker in the Shortcuts editor, and for Siri to resolve a name — at moments
/// when the app is not running at all. See ``SharedStore/knownMacs``.
/// Every `static` property in this file that answers a protocol requirement is a `let` rather than
/// a `var`. AppIntents declares them as `{ get }`, so a `let` satisfies them exactly, and Swift 6
/// reads a stored `static var` as mutable state shared with the framework's own threads. None of
/// these values ever changes, so the distinction costs nothing to make.
struct MacEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mac")
    static let defaultQuery = MacQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct MacQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [MacEntity] {
        SharedStore.knownMacs
            .filter { identifiers.contains($0.id) }
            .map { MacEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [MacEntity] {
        SharedStore.knownMacs.map { MacEntity(id: $0.id, name: $0.name) }
    }

    /// What "my Mac" means with nothing else said: the one used last, which is what the widget's
    /// small size means by a tap too.
    func defaultResult() async -> MacEntity? {
        SharedStore.knownMacs.first.map { MacEntity(id: $0.id, name: $0.name) }
    }
}

/// One of the SSH servers saved in the Servers tab.
///
/// Backed by the App Group copy for the same reason ``MacEntity`` is: Siri has to turn a spoken
/// name into a server, and it does that while the app is not running.
struct ServerEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Server")
    static let defaultQuery = ServerQuery()

    let id: String
    let name: String
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        // The detail is the subtitle rather than part of the title, because two servers can share
        // a name — "prod" on two providers — and the thing that tells them apart is `user@host`.
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
    }
}

struct ServerQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ServerEntity] {
        SharedStore.knownServers
            .filter { identifiers.contains($0.id) }
            .map { ServerEntity(id: $0.id, name: $0.name, detail: $0.detail) }
    }

    func suggestedEntities() async throws -> [ServerEntity] {
        SharedStore.knownServers.map { ServerEntity(id: $0.id, name: $0.name, detail: $0.detail) }
    }

    /// What "my server" means with nothing else said: the one used most recently, which is what
    /// the Servers list puts at the top.
    func defaultResult() async -> ServerEntity? {
        SharedStore.knownServers.first.map {
            ServerEntity(id: $0.id, name: $0.name, detail: $0.detail)
        }
    }
}

struct ConnectToMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect to a Mac"
    static let description = IntentDescription(
        "Opens Peering and connects to one of the Macs you have paired with."
    )
    static let openAppWhenRun = true

    /// Optional on purpose. Most people have one Mac, and "connect to my Mac" should not turn
    /// into a question when there is only one answer.
    @Parameter(title: "Mac")
    var mac: MacEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = IntentHost.model else {
            return .result(dialog: "Peering is not ready yet. Try again in a moment.")
        }

        if let mac {
            model.connectToTrusted(hostID: mac.id)
            return .result(dialog: "Connecting to \(mac.name).")
        }

        model.reconnectToLastHost()
        return .result(dialog: "Connecting to your Mac.")
    }
}

struct DisconnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Disconnect"
    static let description = IntentDescription("Ends the current Peering session.")
    /// No app needed to *stop*: if the app is not running there is no session to end, and
    /// bringing it to the front to say so would be the opposite of what was asked.
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = IntentHost.model, model.phase.holdsSession else {
            return .result(dialog: "Not connected.")
        }
        model.disconnect()
        return .result(dialog: "Disconnected.")
    }
}

struct OpenShellIntent: AppIntent {
    static let title: LocalizedStringResource = "Open a shell"
    static let description = IntentDescription(
        "Opens Peering and starts an SSH shell on one of your saved servers."
    )
    /// The app, because there is nothing else that could open a socket: a shell is a TCP
    /// connection made in this process, exactly as a session is.
    static let openAppWhenRun = true

    /// Optional on purpose, and the same reasoning as ``ConnectToMacIntent``'s — most people have
    /// one server they mean, and "open a shell" should not become a question with one answer.
    @Parameter(title: "Server")
    var server: ServerEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = IntentHost.servers else {
            return .result(dialog: "Peering is not ready yet. Try again in a moment.")
        }

        // Resolved against the *app's* list rather than the mirrored copy: the mirror is what
        // Siri chose from, but this is the list the connection is actually made from, and they
        // can differ by one deletion.
        let host: SSHHost?
        if let server {
            host = model.hosts.first { $0.id.uuidString == server.id }
        } else {
            host = model.hosts.first
        }

        guard let host else {
            return .result(dialog: "You have not saved any servers yet.")
        }

        model.openShellFromIntent(host)
        // Says what it did, not what it hopes: with no saved password the app is about to ask for
        // one, and a dialog claiming a shell is open would be wrong for as long as it takes to
        // type it.
        return .result(
            dialog: model.hasStoredPassword(for: host)
                ? "Opening a shell on \(host.displayName)."
                : "Opening \(host.displayName). Peering needs your password."
        )
    }
}

struct EndShellsIntent: AppIntent {
    static let title: LocalizedStringResource = "End my shells"
    static let description = IntentDescription("Ends every SSH shell Peering has open.")
    /// No app needed to *stop*, for the reason ``DisconnectIntent`` gives: with the app not
    /// running there are no shells, and bringing it forward to say so would be the opposite of
    /// what was asked.
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = IntentHost.servers, !model.openShells.isEmpty else {
            return .result(dialog: "No shells are open.")
        }
        let count = model.openShells.count
        model.closeAllShells()
        return .result(dialog: count == 1 ? "Ended your shell." : "Ended \(count) shells.")
    }
}

/// The phrases Siri already knows, without the user building anything in Shortcuts first.
///
/// Every phrase has to contain `\(.applicationName)` — that is the rule that keeps a shortcut
/// from being claimable by two apps at once, and a phrase without it is rejected at build time
/// rather than quietly ignored at run time.
struct PeeringShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectToMacIntent(),
            phrases: [
                "Connect \(.applicationName) to my Mac",
                "Connect \(.applicationName)",
            ],
            shortTitle: "Connect to a Mac",
            systemImageName: "display"
        )

        AppShortcut(
            intent: DisconnectIntent(),
            phrases: [
                "Disconnect \(.applicationName)",
                "Stop \(.applicationName)",
            ],
            shortTitle: "Disconnect",
            systemImageName: "xmark.circle"
        )

        // Both forms of the phrase, and the parameterised one is not a nicety: without it Siri
        // can only ever be told "a shell" and has to ask which server every single time, even
        // when the user just said its name.
        AppShortcut(
            intent: OpenShellIntent(),
            phrases: [
                "Open a shell on \(\.$server) in \(.applicationName)",
                "Open a shell in \(.applicationName)",
                "Connect to a server in \(.applicationName)",
            ],
            shortTitle: "Open a shell",
            systemImageName: "terminal"
        )

        AppShortcut(
            intent: EndShellsIntent(),
            phrases: [
                "End my shells in \(.applicationName)",
                "Close my shells in \(.applicationName)",
            ],
            shortTitle: "End my shells",
            systemImageName: "xmark.circle"
        )
    }
}
