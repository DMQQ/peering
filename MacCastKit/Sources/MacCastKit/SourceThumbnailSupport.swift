import Foundation

/// Asking a Mac to photograph its running applications, and the one question that has to be
/// answered first.
///
/// The same rule as ``MosaicSupport`` and ``PicturePause``, for the same reason: the request is a
/// command an older host cannot decode, so sending one to a Mac that has not said it understands
/// it does not degrade a picture, it ends the session.
public enum SourceThumbnailSupport {
    /// Whether a client may ask this Mac for thumbnails.
    ///
    /// **An explicit `true` and nothing else.** ``ServerHello/supportsSourceThumbnails`` is an
    /// optional additive field, so it has three states and only one of them is permission:
    ///
    /// - `true` is a Mac that has heard the question and will take pictures.
    /// - `nil` is a Mac built before the field existed, which has never heard the question.
    /// - `false` is a Mac that knows about it and has said it will not.
    ///
    /// `nil` read as "not false, so probably fine" is the natural mistake, and here it would cost
    /// the session at the moment the user opened the Apps panel: this command is sent from that
    /// panel opening, which is an ordinary thing to do, and an unknown command is a decode
    /// failure rather than an ignored message.
    ///
    /// The *pictures* need no flag of their own. ``CaptureSourceDescriptor/thumbnail`` is an
    /// optional field read leniently, so a client that predates it ignores it and one that has it
    /// reads `nil` from a Mac that has none. A grid drawn from a catalogue with no pictures is
    /// its own outline and a name, which is the honest thing to show.
    public static func maySend(hostDeclared declared: Bool?) -> Bool {
        declared == true
    }
}
