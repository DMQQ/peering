import AppIntents
import RemoteCore
import SSHCore
import SwiftUI

/// Intents cannot quietly run in the background. A session is a certificate identity and two sockets
/// opened in this process, so an intent that wanted one without the app being open would have
/// nothing to open it with — see ``SessionModel``'s note on why the model is owned by the `App`.
/// `openAppWhenRun` is the honest description of that, not a workaround.

/// `SessionModel` is owned by the `App` struct and has no view hierarchy an intent could read it
/// from, so the app hands it over once at launch. Weak, because the app's ownership is the real
/// one: an intent must never be the thing keeping a session alive.
@MainActor
enum IntentHost {
    static weak var model: SessionModel?

    static weak var servers: SSHModel?
}

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

    func defaultResult() async -> MacEntity? {
        SharedStore.knownMacs.first.map { MacEntity(id: $0.id, name: $0.name) }
    }
}

struct ServerEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Server")
    static let defaultQuery = ServerQuery()

    let id: String
    let name: String
    let detail: String

    var displayRepresentation: DisplayRepresentation {
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
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // **Any Mac, not the one on screen.** With several open, asking about the active
        // session's phase would answer "not connected" while two other Macs are connected, and
        // the phrase is the same one a user says to mean stop everything.
        guard let model = IntentHost.model, model.hasOpenSession else {
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
    static let openAppWhenRun = true

    @Parameter(title: "Server")
    var server: ServerEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = IntentHost.servers else {
            return .result(dialog: "Peering is not ready yet. Try again in a moment.")
        }

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
        return .result(
            dialog: model.hasStoredCredential(for: host)
                ? "Opening a shell on \(host.displayName)."
                : "Opening \(host.displayName). Peering needs your password."
        )
    }
}

struct EndShellsIntent: AppIntent {
    static let title: LocalizedStringResource = "End my shells"
    static let description = IntentDescription("Ends every SSH shell Peering has open.")
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

/// Every phrase has to contain `\(.applicationName)` — that is the rule that keeps a shortcut
/// from being claimable by two apps at once, and a phrase without it is rejected at build time
/// rather than quietly ignored at run time.
struct PeeringShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectToMacIntent(),
            phrases: [
                // Not "to my Mac": the App Store refuses any Siri phrase containing "mac"
                // (error 90626), in every language, and the phrase cannot ship without it.
                "Connect \(.applicationName) to my computer",
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
