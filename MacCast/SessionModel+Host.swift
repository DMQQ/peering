import Foundation
import MacCastKit
import RemoteCore
import SwiftUI
import WidgetKit

extension SessionModel {

    // MARK: - Host naming

    static let hostNamesKey = "Peering.hostNames"
    static let customHostNamesKey = "Peering.customHostNames"

    func displayName(forHostID id: String) -> String? { customHostNames[id] ?? hostNames[id] }

    /// Names a Mac, or puts its own name back if the new one is empty.
    func rename(hostID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            customHostNames.removeValue(forKey: hostID)
        } else {
            customHostNames[hostID] = trimmed
        }
        UserDefaults.standard.set(customHostNames, forKey: Self.customHostNamesKey)
        publishKnownMacs()
    }

    /// Hands the widget its copy of the paired list.
    ///
    /// Pushed rather than pulled, because the widget is a separate process with no way to ask:
    /// the only moment this can be written is when the app changes something. Called from the
    /// four places that can — a pairing being established, a Mac being forgotten, a Mac
    /// reporting a new name, and a rename — which is the whole of the list.
    ///
    /// Most recently connected first, because the widget has room for a few and the Mac someone
    /// wants is almost always the one they used last.
    func publishKnownMacs() {
        let ordered = pairedHostIDs.sorted {
            (lastConnectedAt[$0] ?? .distantPast) > (lastConnectedAt[$1] ?? .distantPast)
        }
        SharedStore.knownMacs = ordered.map {
            SharedStore.KnownMac(id: $0, name: displayName(forHostID: $0) ?? String(localized: "A Mac"))
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "PeeringQuickConnect")
    }

    /// Hands the widget the live picture: which Macs are open, and which one is on screen.
    ///
    /// Pushed rather than pulled, like ``publishKnownMacs()`` and for the same reason.
    /// The name is written here too, and writing it is what makes "the Mac you used last"
    /// mean the Mac you were looking at.
    func publishOpenMacs() {
        SharedStore.connectedMacIDs = openSessions.compactMap(\.hostID)
        SharedStore.activeMacID = activeSession?.hostID
        if let name = activeSession?.hostName {
            SharedStore.lastHostName = name
            UserDefaults.standard.set(name, forKey: Self.lastHostNameKey)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "PeeringQuickConnect")
    }
}
