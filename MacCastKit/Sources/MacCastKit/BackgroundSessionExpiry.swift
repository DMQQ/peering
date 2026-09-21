/// Decides whether an expiring iOS background assertion still owns the session it was created for.
///
/// Kept outside UIKit so the race between the expiration callback and a foreground return can be
/// tested without running an application scene. The callback is allowed to end a session only
/// while that same assertion is active and the app is still in the background.
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
