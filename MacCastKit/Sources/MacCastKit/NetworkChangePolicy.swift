import Foundation

/// The phone's own network, in the only terms the reconnect decision needs. Declared here and
/// produced in the app, because what matters is a comparison between two of these and `NWPath`
/// cannot be constructed in a test.
public struct NetworkPathSnapshot: Equatable, Sendable {
    public var isSatisfied: Bool
    public var interfaces: Set<Interface>

    public init(isSatisfied: Bool, interfaces: Set<Interface>) {
        self.isSatisfied = isSatisfied
        self.interfaces = interfaces
    }

    public enum Interface: String, Sendable, Hashable, CaseIterable {
        case wifi
        case cellular
        case wired
        case other
    }
}

/// Decides when a change of network is worth abandoning a reconnect backoff for.
public struct NetworkChangePolicy: Sendable {
    private var lastDialledOn: NetworkPathSnapshot?

    public init() {}

    /// Whether this path is different enough from the one last dialled on to be worth dialling
    /// again for.
    public mutating func shouldDialNow(for path: NetworkPathSnapshot) -> Bool {
        guard path.isSatisfied else {
            lastDialledOn = nil
            return false
        }
        // The same usable path as last time is not news: iOS reports a single handover as several
        // updates, and acting on it twice is a second dial for one switch.
        return path != lastDialledOn
    }

    public mutating func noteDialled(on path: NetworkPathSnapshot) {
        lastDialledOn = path
    }
}
