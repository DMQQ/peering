/// The access checks performed before Picture in Picture is armed or started.
public enum PictureInPictureAccess {
    public static func canArm(access: PlanAccess) -> Bool {
        guard let plan = access.plan else { return false }
        return plan.includes(.pictureInPicture)
    }

    public static func canStart(isOnPlan: Bool) -> Bool {
        isOnPlan
    }
}
