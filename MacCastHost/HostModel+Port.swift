import Foundation
import RemoteCore

// MARK: - Port

extension HostModel {
    static let portKey = "hostPort"

    /// The port this Mac listens on.
    ///
    /// Read once at launch and written when it changes, because a Mac that needs a different port
    /// needs it every time. Out of range or unset falls back to the default, so a bad value in the
    /// defaults store cannot leave the host unable to start.
    static func storedPort() -> UInt16 {
        let stored = UserDefaults.standard.integer(forKey: portKey)
        guard let port = UInt16(exactly: stored), port > 0 else { return ProtocolInfo.defaultPort }
        return port
    }

    /// What the menu bar icon should be showing.
    ///
    /// Computed here rather than in the scene: an `@Observable` read inside `MenuBarExtra`'s label
    /// is what invalidates it.
    var menuBarState: HostMenuBarState {
        guard permissions.allRequiredGranted else { return .setupRequired }
        guard status.isListening else { return .stopped }
        if !connectedClients.isEmpty { return .streaming }
        return pairedClientIDs.isEmpty ? .waiting : .ready
    }

    /// The port that is actually bound, once there is one.
    ///
    /// Preferred over ``port`` for anything shown to the user: the two agree while the listener is
    /// up, and while it is down the configured value is a claim about the future.
    var boundPort: UInt16 {
        if case .listening(let bound) = status { return bound }
        return port
    }

    /// Changes the port, and restarts the listener if one is running.
    ///
    /// A restart rather than a rebind, because there is no rebinding: the port is fixed when the
    /// listener is created. Heavy for one number, since the capture stream and every connected
    /// device go with it, but the alternative is a host that reports one port and listens on
    /// another.
    func setPort(_ newPort: UInt16) {
        guard newPort != port, newPort > 0 else { return }
        port = newPort
        UserDefaults.standard.set(Int(newPort), forKey: Self.portKey)

        guard server != nil else { return }
        stop()
        start()
    }
}
