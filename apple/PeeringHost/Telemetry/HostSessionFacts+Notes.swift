import Foundation
import PeeringKit

/// Named notes for the places that end a session, so those files need not know the closed sets.
extension HostSessionFacts {
    func hostStopped() { noteEndForAll(.hostStopped) }

    func allForgotten() { noteEndForAll(.forgotten) }

    func forgotten(clientID: String) { noteEnd(clientID: clientID, .forgotten) }

    func connectionFailed(clientID: String) { noteEnd(clientID: clientID, .error) }

    func silent(clientID: String, inBackground: Bool) {
        noteEnd(clientID: clientID, inBackground ? .backgroundedSilence : .silence)
    }
}
