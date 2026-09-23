import Foundation

/// The access check performed before a terminal is allowed to reach for the user.
///
/// Two things ask it, at the two moments the answer can still stop something: a session coming up,
/// which decides whether to hand the Mac the device token it would be pushed to; and a shell
/// stopping, which decides whether to put a banner up about it.
///
/// It fails closed on an unread plan, unlike every control in the app: a control can treat an
/// unanswered entitlement as temporarily available because the user still has to tap it, and
/// nothing here waits for a tap. The entitlement is read once at launch, so this refuses only until
/// StoreKit has spoken.
public enum TerminalAlertsAccess {
    /// Whether the plan includes being told, and `false` while that is not yet known.
    public static func canNotify(access: PlanAccess) -> Bool {
        guard let plan = access.plan else { return false }
        return plan.includes(.terminalAlerts)
    }
}
