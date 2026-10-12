import Foundation
import RemoteCore

// MARK: - Port

extension HostModel {
    static let portKey = "hostPort"

    static func storedPort() -> UInt16 {
        let stored = UserDefaults.standard.integer(forKey: portKey)
        guard let port = UInt16(exactly: stored), port > 0 else { return ProtocolInfo.defaultPort }
        return port
    }

    /// Computed here rather than in the label view: an `@Observable` read inside the status item's
    /// hosted label is what invalidates it.
    var menuBarState: HostMenuBarState {
        guard permissions.allRequiredGranted else { return .setupRequired }
        guard status.isListening else { return .stopped }
        if !connectedClients.isEmpty { return .streaming }
        return pairedClientIDs.isEmpty ? .waiting : .ready
    }

    var boundPort: UInt16 {
        if case .listening(let bound) = status { return bound }
        return port
    }

    /// Restarts rather than rebinds: the port is fixed when the listener is created.
    func setPort(_ newPort: UInt16) {
        guard newPort != port, newPort > 0 else { return }
        port = newPort
        UserDefaults.standard.set(Int(newPort), forKey: Self.portKey)

        guard server != nil else { return }
        stop()
        start()
    }
}
