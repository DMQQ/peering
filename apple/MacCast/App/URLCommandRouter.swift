import MacCastKit
import Observation
import RemoteCore
import SwiftUI

/// Runs `peering://` commands under ``URLCommandPolicy``: nothing runs behind the app lock, and ending a live session or its shells asks first.
/// The widget and Live Activity End buttons arrive by the same links, so they ask too.
@Observable
@MainActor
final class URLCommandRouter {
    /// Starts locked until the root view says otherwise, so a link that launches the app cannot beat the lock.
    private(set) var isLocked = true
    /// The ending command waiting for an answer; the alert reads it.
    var confirming: URLCommand?
    private var held: URLCommand?

    func setLocked(_ locked: Bool, model: SessionModel, servers: SSHModel) {
        isLocked = locked
        guard !locked, let command = held else { return }
        held = nil
        handle(command, model: model, servers: servers)
    }

    func handle(_ url: URL, model: SessionModel, servers: SSHModel) {
        guard let command = URLCommandPolicy.parse(url) else { return }
        handle(command, model: model, servers: servers)
    }

    func confirm(model: SessionModel, servers: SSHModel) {
        guard let command = confirming else { return }
        confirming = nil
        perform(command, model: model, servers: servers)
    }

    private func handle(_ command: URLCommand, model: SessionModel, servers: SSHModel) {
        switch URLCommandPolicy.decide(
            command,
            isLocked: isLocked,
            hasLiveSession: model.sessions.contains { $0.isLive },
            hasLiveShells: !servers.openShells.isEmpty
        ) {
        case .run: perform(command, model: model, servers: servers)
        case .confirm: confirming = command
        case .holdUntilUnlock: held = command
        }
    }

    private func perform(_ command: URLCommand, model: SessionModel, servers: SSHModel) {
        switch command {
        case .connect(let requested):
            // The medium widget names a Mac per row; without an id (the small tile) it is the Mac used last.
            if let requested, model.pairedHostIDs.contains(requested) {
                model.connectToTrusted(hostID: requested)
            } else {
                model.reconnectToLastHost()
            }
        case .chat(let chatID, let hostID):
            // A chat lives on its Mac: that Mac is opened first, and the chat is asked for once its screen is up (see `InAppBanner.openRequest`).
            if let hostID { model.openFromNotification(hostID: hostID, sourceID: nil) }
            InAppBanner.shared.openRequest = .chat(chatID)
        case .pairingCode(let url):
            model.pairingLink = (url, .now)
            // The code belongs to a Mac that is asking right now; with none asking it is held for a minute and the person is told what to do, since nothing on screen changes otherwise.
            if case .confirming = model.phase { break }
            InAppBanner.shared.post(InAppBannerItem(
                symbol: "qrcode.viewfinder",
                title: String(localized: "Pairing code"),
                summary: String(localized: "Choose your Mac under Nearby first"),
                body: String(localized: "Tap your Mac in the list, and this code is used as soon as it asks. It stays valid for a minute."),
                needsYou: false,
                target: nil
            ))
        case .disconnect:
            model.disconnect()
        case .endShells:
            servers.closeAllShells()
        }
    }

    var confirmationTitle: String {
        switch confirming {
        case .endShells: return String(localized: "Close all shells?")
        default: return String(localized: "End this session?")
        }
    }

    var confirmationMessage: String {
        switch confirming {
        case .endShells: return String(localized: "Every open shell on this phone will be closed.")
        default: return String(localized: "You will be disconnected from your Mac.")
        }
    }
}
