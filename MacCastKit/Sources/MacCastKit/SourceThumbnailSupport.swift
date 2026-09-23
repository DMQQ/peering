import Foundation

/// Asking a Mac to photograph its running applications, and the one question that has to be
/// answered first.
///
/// The request is a command an older host cannot decode, so sending one to a Mac that has not said
/// it understands it does not degrade a picture, it ends the session.
public enum SourceThumbnailSupport {
    /// Whether a client may ask this Mac for thumbnails.
    ///
    /// Only an explicit `true`. ``ServerHello/supportsSourceThumbnails`` is optional and additive, so
    /// it has three states: `true` is a Mac that will take pictures, `nil` is a Mac built before the
    /// field existed, `false` is a Mac that has said it will not. The command is sent from the Apps
    /// panel opening, and an unknown command is a decode failure rather than an ignored message, so
    /// `nil` read as "not false, so probably fine" costs the session.
    ///
    /// The pictures need no flag of their own: ``CaptureSourceDescriptor/thumbnail`` is optional and
    /// read leniently, so a client that predates it simply ignores it.
    public static func maySend(hostDeclared declared: Bool?) -> Bool {
        declared == true
    }
}
