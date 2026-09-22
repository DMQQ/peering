import Foundation

/// The access check performed before a terminal is allowed to reach for the user.
///
/// Two things ask this question and they ask it at the two moments the answer can still stop
/// something: the phone, as a session comes up and it decides whether to hand the Mac the device
/// token it would be pushed to; and the phone again, as a shell stops, when it decides whether to
/// put a banner up about it.
///
/// **It fails closed on an unread plan, unlike every control in the app.** A control can treat an
/// unanswered entitlement as temporarily available because the user still has to tap it after the
/// answer lands. Nothing here waits for a tap: the token is registered by a session starting and
/// the banner is raised by a shell stopping, and both happen without the user doing anything, so
/// an unanswered plan has to mean no rather than yes. The cost of being wrong that way is a
/// subscriber missing one banner in the first moments of a launch; the other way it is the paid
/// feature spending itself for somebody who has not bought it.
///
/// **The window is the first moments of a launch and no more.** The entitlement is read once, at
/// launch, and the answer never goes back to being unknown, so this refuses only until StoreKit
/// has spoken, which is well before a session has browsed, handshaked and come up.
public enum TerminalAlertsAccess {
    /// Whether the plan includes being told, and `false` while that is not yet known.
    public static func canNotify(access: PlanAccess) -> Bool {
        guard let plan = access.plan else { return false }
        return plan.includes(.terminalAlerts)
    }
}
