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

    public static func shouldUpgrade(
        path: ConnectionPath?,
        macVisibleOnLAN: Bool,
        secondsSinceLastAttempt: TimeInterval?
    ) -> Bool {
        guard macVisibleOnLAN, let path, path != .lan else { return false }
        return secondsSinceLastAttempt.map { $0 >= cooldownSeconds } ?? true
    }
}
