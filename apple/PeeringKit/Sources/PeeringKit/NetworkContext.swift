import Foundation

/// The phone's network as an analytics event sees it: an interface kind and two flags, plus a running count of changes so a session can report how many happened during it.
public struct NetworkContext: Sendable, Equatable {
    public var interface: String
    public var isExpensive: Bool
    public var isConstrained: Bool
    /// Since launch; a session subtracts the value it started with.
    public var pathChanges: Int

    public init(interface: String = "none", isExpensive: Bool = false, isConstrained: Bool = false, pathChanges: Int = 0) {
        self.interface = interface
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.pathChanges = pathChanges
    }

    /// The interface traffic would prefer: a cable, then Wi-Fi, then cellular.
    public static func primaryInterface(of interfaces: Set<NetworkPathSnapshot.Interface>, isSatisfied: Bool) -> String {
        guard isSatisfied else { return "none" }
        for kind in [NetworkPathSnapshot.Interface.wired, .wifi, .cellular, .other] where interfaces.contains(kind) {
            return kind.rawValue
        }
        return "none"
    }

    public func changes(since baseline: Int) -> Int { max(0, pathChanges - baseline) }
}
