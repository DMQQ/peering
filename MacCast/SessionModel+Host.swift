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

    /// Pushed because the widget is a separate process that cannot ask; called from the four places that change the list.
    /// Most recently connected first, since the widget has room for a few.
    func publishKnownMacs() {
        let ordered = pairedHostIDs.sorted {
            (lastConnectedAt[$0] ?? .distantPast) > (lastConnectedAt[$1] ?? .distantPast)
        }
        SharedStore.knownMacs = ordered.map {
            SharedStore.KnownMac(id: $0, name: displayName(forHostID: $0) ?? String(localized: "A Mac"))
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "PeeringQuickConnect")
    }

    /// The name is written too, which makes "the Mac you used last" mean the one you were looking at.
    func publishOpenMacs() {
        SharedStore.connectedMacIDs = openSessions.compactMap(\.hostID)
        SharedStore.activeMacID = activeSession?.hostID
        if let name = activeSession?.hostName {
            SharedStore.lastHostName = name
            UserDefaults.standard.set(name, forKey: Self.lastHostNameKey)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "PeeringQuickConnect")
        AgentWidgetPublisher.shared.prune(keeping: Set(openSessions.compactMap { $0.hostID ?? $0.hostName ?? $0.id.uuidString }))
    }
}
