import Foundation

/// Fails closed on an unread plan, unlike controls: a control can treat an unanswered entitlement as available because the user still taps it, but nothing here waits for a tap. The entitlement is read once at launch, so this refuses only until StoreKit has spoken.
public enum TerminalAlertsAccess {
    public static func canNotify(access: PlanAccess) -> Bool {
        guard let plan = access.plan else { return false }
        return plan.includes(.terminalAlerts)
    }
}
