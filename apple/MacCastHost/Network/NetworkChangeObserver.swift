import AppKit
import Network

/// Calls back when this Mac wakes or its network path changes, the two moments a signalling socket is most likely to be half open.
final class NetworkChangeObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "pl.dmq.peering.host.path-monitor")
    private var wakeToken: (any NSObjectProtocol)?
    private let lock = NSLock()
    private var change = NetworkPathChange()

    init(onChange: @escaping @Sendable () -> Void) {
        wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { _ in onChange() }

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let changed = lock.withLock {
                change.update(isSatisfied: path.status == .satisfied, interfaceNames: path.availableInterfaces.map(\.name))
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
