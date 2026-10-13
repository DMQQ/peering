import Foundation
import MacCastKit
import RemoteCore

extension HostServer {
    func broadcastCatalog(_ catalog: CaptureCatalog) {
        broadcast { $0.sendCatalog(catalog) }
    }

    func broadcastNotice(_ payload: NoticePayload) {
        broadcast { $0.sendNotice(payload) }
    }

    func broadcastTextFocus(_ focus: TextFocus) {
        broadcast { $0.sendTextFocus(focus) }
    }

    func broadcastFieldState(_ state: FieldState) {
        broadcast { $0.sendFieldState(state) }
    }

    func broadcastPointer(_ point: NormalizedPoint) {
        broadcast { $0.sendPointer(point) }
    }

    private func broadcast(_ send: @escaping @Sendable (HostSession) -> Void) {
        queue.async { [weak self] in
            self?.connections.sessions.forEach(send)
        }
    }

    func emit(_ event: HostEvent) {
        // A phone that reconnects, or races two routes, can still hold a second connection when one
        // closes. That close is not the phone leaving, and passing it on would end the live one's
        // session, watchers and shells. The closing session is still listed while it reports.
        if case .clientDisconnected(let clientID, _) = event, connections.authorizedCount(clientID: clientID) > 1 {
            return
        }
        callbacks.onEvent?(event)
    }
}
