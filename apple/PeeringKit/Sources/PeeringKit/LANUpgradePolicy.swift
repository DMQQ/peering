import Foundation

/// When a session carried by the relay or a punched hole should move to the Mac's own network.
///
/// A brief Wi-Fi hiccup sends a phone to the relay, and nothing moved it back: the user had to end the session and
/// connect again. The move costs a short interruption, so it waits until the Mac has stayed in view and does not repeat
/// when the LAN dial keeps failing.
public enum LANUpgradePolicy {
    /// The Mac must have been visible on the LAN this long, so a service that flickers in and out does not trigger it.
    public static let settleSeconds: TimeInterval = 3
    /// The least time between two attempts for one session.
    public static let cooldownSeconds: TimeInterval = 90

    /// How often a session still off the LAN is looked at again. The trigger used to be an event, a path change or a Mac appearing, and one missed because the Mac was not yet in view left the session where it was for good.
    public static let pollSeconds: TimeInterval = 10
    /// Attempts per Mac on one network. A Mac that is visible but cannot be reached (a guest network that isolates devices) would otherwise be redialled for as long as the session lasts, and every redial interrupts it.
    public static let maxAttemptsPerNetwork = 3

    /// Only Wi-Fi and a cable can be the Mac's network: on cellular the Mac is visible only if a stale record says so.
    public static func canReachLAN(interface: String) -> Bool {
        interface == "wifi" || interface == "wired"
    }

    public static func shouldUpgrade(
        path: ConnectionPath?,
        macVisibleOnLAN: Bool,
        secondsSinceLastAttempt: TimeInterval?,
        attemptsOnThisNetwork: Int = 0
    ) -> Bool {
        guard macVisibleOnLAN, let path, path != .lan, attemptsOnThisNetwork < maxAttemptsPerNetwork else { return false }
        return secondsSinceLastAttempt.map { $0 >= cooldownSeconds } ?? true
    }
}
