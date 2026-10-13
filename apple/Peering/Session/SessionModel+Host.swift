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

    /// What a screen shows for a Mac that may have been renamed: the user's name, else the Mac's own.
    func shownName(hostID: String?, fallback: String) -> String {
        hostID.flatMap { customHostNames[$0] } ?? fallback
    }

    func rename(hostID: String, to name: String) {
        Analytics.featureUsed(.macRenamed)
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
        if let session = activeSession, let actual = session.hostName {
            let name = shownName(hostID: session.hostID, fallback: actual)
            SharedStore.lastHostName = name
            UserDefaults.standard.set(name, forKey: Self.lastHostNameKey)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "PeeringQuickConnect")
        AgentWidgetPublisher.shared.prune(keeping: Set(openSessions.compactMap { $0.hostID ?? $0.hostName ?? $0.id.uuidString }))
    }
}
