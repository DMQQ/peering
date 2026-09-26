import Foundation
import MacCastKit
import Network

/// Watches the phone's own network, so that a switch can be answered at once instead of after a
/// reconnect backoff has run its course.
///
/// **Why the app has to watch this itself.** A control connection can only report the network it
/// was already using: when the interface under it disappears, the socket fails on the system's
/// schedule, and from that moment the app's own ladder decides how long the user waits. That ladder
/// counts in seconds because its usual cause is a Mac that is asleep. A phone that has just moved
/// to a network it did not have a moment ago is a different situation with the same symptom, and it
/// is over in a few hundred milliseconds, so it is worth being told about rather than waited out.
///
/// The decision is not here. This type does the I/O, the coalescing and the asking; what counts as
/// a change worth dialling for is ``NetworkChangePolicy``, which is checkable without a radio.
@MainActor
final class NetworkPathWatcher {
    private let monitor = NWPathMonitor()
    /// Its own queue, because `NWPathMonitor` refuses to start without one and this is the queue it
    /// delivers on. Nothing here touches state off the main actor: the handler hops first.
    private let queue = DispatchQueue(label: "pl.dmq.peering.network-path")

    /// The comparison, and the record of what it last dialled on.
    private var policy = NetworkChangePolicy()

    /// The newest path seen, and the task that will judge it once the updates stop arriving.
    ///
    /// **A switch is several updates, not one.** Taken one at a time, a handover would dial as
    /// Wi-Fi leaves and again as cellular arrives, which is two connections asked for where one was
    /// wanted and the second tearing down the first on its way past. Waiting for the updates to
    /// stop costs a fraction of a second and makes one switch one dial.
    private var latest: NetworkPathSnapshot?
    private var settle: Task<Void, Never>?

    /// How long to wait for the path to stop changing before acting on it.
    private static let settleFor: Duration = .milliseconds(250)

    /// Called when the network has moved and the app should dial at once.
    var onUsableChange: (() -> Void)?

    /// Asked before anything is dialled: whether there is a Mac to put back.
    ///
    /// A closure rather than a flag because the watcher has no business knowing what a session is,
    /// and because the answer changes for reasons that have nothing to do with the network.
    var hasSomethingToPutBack: (() -> Bool)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = NetworkPathSnapshot(
                isSatisfied: path.status == .satisfied,
                interfaces: Self.interfaces(of: path)
            )
            Task { @MainActor in self?.received(snapshot) }
        }
        monitor.start(queue: queue)
    }

    /// Judges the newest path now, without waiting for it to stop moving.
    ///
    /// Called by the settle timer when a report arrives, and called directly when a wait begins.
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

    /// Called once a changed path has settled, whether or not anything is being put back.
    var onPathChange: (() -> Void)?

    private func received(_ snapshot: NetworkPathSnapshot) {
        let changed = latest != nil && latest != snapshot
        latest = snapshot
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: Self.settleFor)
            guard !Task.isCancelled else { return }
            if changed { self?.onPathChange?() }
            self?.judgeNow()
        }
    }

    /// What the path is made of, in the coarse terms the decision uses.
    ///
    /// `usesInterfaceType` rather than the interface list, because the question is what this app's
    /// traffic would go over and not what the phone has available: a phone that is on Wi-Fi with
    /// cellular in reserve reports both as available and one as in use.
    ///
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
