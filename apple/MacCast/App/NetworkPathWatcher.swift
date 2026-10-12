import Foundation
import MacCastKit
import Network

@MainActor
final class NetworkPathWatcher {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "pl.dmq.peering.network-path")

    private var policy = NetworkChangePolicy()

    /// **A switch is several updates, not one.** Taken one at a time, a handover would dial as
    /// Wi-Fi leaves and again as cellular arrives, which is two connections asked for where one was
    /// wanted and the second tearing down the first on its way past. Waiting for the updates to
    /// stop costs a fraction of a second and makes one switch one dial.
    private var latest: NetworkPathSnapshot?
    private var settle: Task<Void, Never>?

    private static let settleFor: Duration = .milliseconds(250)

    var onUsableChange: (() -> Void)?

    var hasSomethingToPutBack: (() -> Bool)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = NetworkPathSnapshot(
                isSatisfied: path.status == .satisfied,
                interfaces: Self.interfaces(of: path)
            )
            let flags = (isExpensive: path.isExpensive, isConstrained: path.isConstrained)
            Task { @MainActor in self?.received(snapshot, flags: flags) }
        }
        monitor.start(queue: queue)
    }

    /// **The second caller is the one that matters on a relay session**, where the socket can hang
    /// for the whole of the ten seconds the silence watchdog allows: a phone that changed network
    /// during that had its change reported while nothing was being put back, which is no reason to
    /// dial and so was not acted on. The drop then lands on a network that has already moved, and
    /// this is what notices instead of the ladder sleeping through it.
    func judgeNow() {
        guard let path = latest, policy.shouldDialNow(for: path) else { return }
        // Asked before the path is recorded, and the order is the whole of it: a moment with
        // nothing to put back must leave the change unspent, so that the drop arriving afterwards
        // still finds it new. See ``NetworkChangePolicy/shouldDialNow(for:)``.
        guard hasSomethingToPutBack?() == true else { return }
        policy.noteDialled(on: path)
        onUsableChange?()
    }

    var onPathChange: (() -> Void)?

    /// What analytics reports about the network. Its change count moves on the same comparison that drives a redial.
    private(set) var context = NetworkContext()

    private func received(_ snapshot: NetworkPathSnapshot, flags: (isExpensive: Bool, isConstrained: Bool)) {
        let changed = latest != nil && latest != snapshot
        latest = snapshot
        context = NetworkContext(
            interface: NetworkContext.primaryInterface(of: snapshot.interfaces, isSatisfied: snapshot.isSatisfied),
            isExpensive: flags.isExpensive,
            isConstrained: flags.isConstrained,
            pathChanges: context.pathChanges + (changed ? 1 : 0)
        )
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: Self.settleFor)
            guard !Task.isCancelled else { return }
            if changed { self?.onPathChange?() }
            self?.judgeNow()
        }
    }

    /// `nonisolated` because the handler that calls it runs on the monitor's own queue, and this is
    /// the one thing done there before hopping: it reads the path it was handed and nothing else,
    /// so there is no state for the main actor to be protecting.
    private nonisolated static func interfaces(of path: NWPath) -> Set<NetworkPathSnapshot.Interface> {
        var kinds: Set<NetworkPathSnapshot.Interface> = []
        if path.usesInterfaceType(.wifi) { kinds.insert(.wifi) }
        if path.usesInterfaceType(.cellular) { kinds.insert(.cellular) }
        if path.usesInterfaceType(.wiredEthernet) { kinds.insert(.wired) }
        if path.usesInterfaceType(.other) { kinds.insert(.other) }
        return kinds
    }
}
