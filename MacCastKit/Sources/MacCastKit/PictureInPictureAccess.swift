/// The access checks performed before Picture in Picture is armed or started.
///
/// Most controls can treat an unread StoreKit entitlement as temporarily available because the
/// user still has to tap them after the answer arrives. PiP can start merely because the app is
/// backgrounded, so it must fail closed until a known paid plan has been read.
public enum PictureInPictureAccess {
    public static func canArm(access: PlanAccess) -> Bool {
        guard let plan = access.plan else { return false }
        return plan.includes(.pictureInPicture)
    }

    public static func canStart(isOnPlan: Bool) -> Bool {
        isOnPlan
    }
}
