/// Whether the reconnect ladder may dial on its own timer. Outside UIKit so it can be tested without an application scene.
///
/// A backgrounded app that is not showing Picture in Picture is frozen by iOS within seconds, so a dial from its timer connects for a moment, is frozen again, and spends relay time on a session nobody can see. The dial waits for the app to come back instead. An explicit request (a notification button, the person tapping) does not pass through here.
public enum BackgroundRedial {
    public static func mayDialFromTimer(appIsBackground: Bool, pictureInPictureIsActive: Bool) -> Bool {
        !appIsBackground || pictureInPictureIsActive
    }
}
