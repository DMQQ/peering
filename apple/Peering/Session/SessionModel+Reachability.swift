import PeeringKit
import RemoteCore
import SwiftUI

extension SessionModel {
    func rememberLANHost(_ host: DiscoveredHost) {
        lastLANHosts[host.id] = host
    }

    func rememberedLANHost(_ hostID: String) -> DiscoveredHost? {
        lastLANHosts[hostID]
    }

    /// Not a `Bool`: "not reachable" is two facts and only one is about the Mac.
    enum Reachability: Equatable {
        case nearby
        case viaRelay
        /// Not quite "switched off": a Mac can be awake on its own network while registered nowhere.
        case notRegistered
        case unknown

        var isReachable: Bool {
            switch self {
            case .nearby, .viaRelay: return true
            case .notRegistered, .unknown: return false
            }
        }
    }

    func reachability(ofHost hostID: String) -> Reachability {
        if hosts.contains(where: { $0.id == hostID }) { return .nearby }
        switch relayPresence[hostID] {
        case true?: return .viaRelay
        case false?: return .notRegistered
        case nil: return .unknown
        }
    }
}
