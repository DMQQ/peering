import Foundation

/// Fails closed on an unread plan, unlike controls: a control can treat an unanswered entitlement as available because the user still taps it, but nothing here waits for a tap. The entitlement is read once at launch, so this refuses only until StoreKit has spoken.
public enum TerminalAlertsAccess {
    public static func canNotify(access: PlanAccess) -> Bool {
        guard let plan = access.plan else { return false }
        return plan.includes(.terminalAlerts)
    }

    /// The banner the phone raises itself is free on the home network: a LAN session needs no relay, so nothing metered carries it. The push through the Mac, which reaches a phone with no session open, stays on the paid plan.
    public static func allowsBanner(planIncluded: Bool, onLAN: Bool) -> Bool {
        planIncluded || onLAN
    }
}
