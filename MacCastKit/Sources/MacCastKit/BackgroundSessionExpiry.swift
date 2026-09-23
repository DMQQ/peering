/// Decides whether an expiring iOS background assertion still owns the session it was created for.
///
/// Outside UIKit so the race with a foreground return can be tested without an application scene.
public enum BackgroundSessionExpiry {
    public static func shouldEndSession(
        assertionIsActive: Bool,
        appIsBackground: Bool,
        hasOpenSession: Bool,
        pictureInPictureIsActive: Bool
    ) -> Bool {
        assertionIsActive && appIsBackground && hasOpenSession && !pictureInPictureIsActive
    }
}
