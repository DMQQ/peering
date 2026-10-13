import AppKit
import Network

/// Calls back when this Mac wakes or its network path changes, the two moments a signalling socket is most likely to be half open.
final class NetworkChangeObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "pl.dmq.peering.host.path-monitor")
    private var wakeToken: (any NSObjectProtocol)?
    private let lock = NSLock()
    private var lastSignature: String?

    init(onChange: @escaping @Sendable () -> Void) {
        wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { _ in onChange() }

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, path.status == .satisfied else { return }
            let signature = path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            let changed = lock.withLock { () -> Bool in
                defer { lastSignature = signature }
                // The first update only reports where things already are.
                return lastSignature != nil && lastSignature != signature
            }
            if changed { onChange() }
        }
        monitor.start(queue: monitorQueue)
    }

    func cancel() {
        monitor.cancel()
        if let wakeToken { NSWorkspace.shared.notificationCenter.removeObserver(wakeToken) }
        wakeToken = nil
    }
}
