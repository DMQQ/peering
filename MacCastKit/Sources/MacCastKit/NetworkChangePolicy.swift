import Foundation

/// The phone's own network, in the only terms the reconnect decision needs. Declared here and
/// produced in the app, because what matters is a comparison between two of these and `NWPath`
/// cannot be constructed in a test.
public struct NetworkPathSnapshot: Equatable, Sendable {
    /// Whether the system thinks there is anywhere to send anything.
    public var isSatisfied: Bool
    /// What it would be sent over. A set rather than one value: iOS reports a phone on Wi-Fi with
    /// cellular still up as both, and one member leaving is the change that usually matters.
    public var interfaces: Set<Interface>

    public init(isSatisfied: Bool, interfaces: Set<Interface>) {
        self.isSatisfied = isSatisfied
        self.interfaces = interfaces
    }

    /// The kinds of path this app has an opinion about. Deliberately coarse: nothing here behaves
    /// differently on a wired connection than on Wi-Fi.
    public enum Interface: String, Sendable, Hashable, CaseIterable {
        case wifi
        case cellular
        case wired
        case other
    }
}

/// Decides when a change of network is worth abandoning a reconnect backoff for.
///
/// The ladder's waits fit a Mac that is asleep and are wrong for a phone that has just moved
/// network, and nothing in the ladder tells those apart. It is only ever consulted for a session
/// being put back, a guard the caller owns: a path change during a working session would tear down
/// a connection that was fine.
public struct NetworkChangePolicy: Sendable {
    /// The last path a dial was triggered for.
    private var lastDialledOn: NetworkPathSnapshot?

    public init() {}

    /// Whether this path is different enough from the one last dialled on to be worth dialling
    /// again for.
    ///
    /// Asking does not record; ``noteDialled(on:)`` does. A change marked as dealt with while there
    /// is nothing to dial would leave a later drop finding nothing new.
    public mutating func shouldDialNow(for path: NetworkPathSnapshot) -> Bool {
        guard path.isSatisfied else {
            // Forget rather than merely decline: a network that goes away and comes back reports
            // the interfaces it had before, so holding on to what was dialled on would make the
            // return look like no change at all.
            lastDialledOn = nil
            return false
        }
        // The same usable path as last time is not news: iOS reports a single handover as several
        // updates, and acting on it twice is a second dial for one switch.
        return path != lastDialledOn
    }

    /// Records that a dial was actually made, so the same path is not acted on twice.
    public mutating func noteDialled(on path: NetworkPathSnapshot) {
        lastDialledOn = path
    }
}
