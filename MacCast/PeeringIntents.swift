import AppIntents
import RemoteCore
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
}

/// One of the Macs this phone has paired with.
///
/// Backed by the app-group list rather than the app's own, because Shortcuts asks for the choices
/// — to build the picker in the Shortcuts editor, and for Siri to resolve a name — at moments
/// when the app is not running at all. See ``SharedStore/knownMacs``.
struct MacEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mac")
    static var defaultQuery = MacQuery()

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

struct ConnectToMacIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect to a Mac"
    static var description = IntentDescription(
        "Opens Peering and connects to one of the Macs you have paired with."
    )
    static var openAppWhenRun: Bool = true

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
    static var title: LocalizedStringResource = "Disconnect"
    static var description = IntentDescription("Ends the current Peering session.")
    /// No app needed to *stop*: if the app is not running there is no session to end, and
    /// bringing it to the front to say so would be the opposite of what was asked.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = IntentHost.model, model.phase.holdsSession else {
            return .result(dialog: "Not connected.")
        }
        model.disconnect()
        return .result(dialog: "Disconnected.")
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
    }
}
