import Foundation

/// The phone's own network, in the only terms the reconnect decision needs.
///
/// **Declared here and merely produced in the app**, for the reason ``ConnectionPath`` is: the
/// interesting part of "the network changed" is a comparison between two of these, and a
/// comparison can be checked without a radio. `NWPath` cannot be constructed in a test, so it stays
/// where it belongs, on the other side of this type.
public struct NetworkPathSnapshot: Equatable, Sendable {
    /// Whether the system thinks there is anywhere to send anything.
    public var isSatisfied: Bool
    /// What it would be sent over. A set rather than one value: iOS reports a phone that is on
    /// Wi-Fi with cellular still up as both, and the transition that matters is usually one member
    /// leaving rather than the whole path changing.
    public var interfaces: Set<Interface>

    public init(isSatisfied: Bool, interfaces: Set<Interface>) {
        self.isSatisfied = isSatisfied
        self.interfaces = interfaces
    }

    /// The kinds of path this app has an opinion about.
    ///
    /// Deliberately coarse. Nothing here behaves differently on a wired connection than on Wi-Fi,
    /// and a finer taxonomy would be a list to keep in step with an enum in a framework for no
    /// decision that reads it.
    public enum Interface: String, Sendable, Hashable, CaseIterable {
        case wifi
        case cellular
        case wired
        case other
    }
}

/// Decides when a change of network is worth abandoning a reconnect backoff for.
///
/// **Why this exists at all.** The ladder waits a second, then two, then five before it tries
/// again, which is right when the cause is a Mac that is asleep and wrong when the cause is the
/// phone having just moved to a network it did not have a moment ago. Nothing in the ladder can
/// tell those apart, and the second one is over in a few hundred milliseconds. So the app watches
/// the path itself and dials the moment it changes, and this is the part of that decision that can
/// be reasoned about without a radio.
///
/// **It is only ever consulted for a session that is being put back.** A path change with a working
/// session is not a reason to dial anything, and treating it as one would tear down a connection
/// that was fine. The caller owns that guard; this type owns the rest.
public struct NetworkChangePolicy: Sendable {
    /// The last path a dial was triggered for.
    private var lastDialledOn: NetworkPathSnapshot?

    public init() {}

    /// Whether this path is different enough from the one last dialled on to be worth dialling
    /// again for.
    ///
    /// **Asking is not the same as acting, and this deliberately does not record.** The two are
    /// separated by ``noteDialled(on:)`` because the app asks about the network at moments when it
    /// has nothing to dial: a phone that changes network while no session is being put back would
    /// otherwise have that change marked as dealt with, and the drop that arrives ten seconds
    /// later, the one this whole type exists for, would find nothing new and wait out its ladder
    /// beside a network that is already up.
    public mutating func shouldDialNow(for path: NetworkPathSnapshot) -> Bool {
        guard path.isSatisfied else {
            // **Forget, rather than merely decline.** A network that goes away and comes back is
            // the ordinary shape of a switch, and it comes back reporting the interfaces it had
            // before. Holding on to what was dialled on would make that return look like no change
            // at all, and the app would sit out the rest of its backoff on a network that is
            // already up: the exact wait this exists to remove.
            lastDialledOn = nil
            return false
        }
        // The same usable path as last time is not news, and acting on it twice is a second dial
        // for one switch. iOS reports a single handover as several updates.
        return path != lastDialledOn
    }

    /// Records that a dial was actually made, so the same path is not acted on twice.
    public mutating func noteDialled(on path: NetworkPathSnapshot) {
        lastDialledOn = path
    }
}
