import Foundation

/// Asking a Mac to composite several of its sources into one picture, and the one question that
/// has to be answered first.
///
/// The same rule as ``PicturePause`` and for a sharper version of the same reason: the mosaic is
/// the first request the client can make that an older host cannot even *decode*. A Mac that has
/// never heard of the case throws on the command, in the middle of a session, and the phone is
/// left looking at its last picture while every tap lands on a source the Mac never switched to.
public enum MosaicSupport {
    /// Whether a client may ask this Mac for a mosaic.
    ///
    /// **An explicit `true` and nothing else.** ``ServerHello/supportsMosaic`` is an optional
    /// additive field, so it has three states and only one of them is permission:
    ///
    /// - `true` is a Mac that has heard the question and can build one.
    /// - `nil` is a Mac built before the field existed. It has never heard the question, and the
    ///   failure is not a degraded picture but a dropped session.
    /// - `false` is a Mac that knows about the mosaic and has said it will not build one.
    ///
    /// `nil` read as "not false, so probably fine" is the natural mistake, and here it costs more
    /// than it does anywhere else: the picture does not go quiet, the *session* ends, because an
    /// unknown `CaptureSource` case is a decode failure rather than an ignored message.
    public static func maySend(hostDeclared declared: Bool?) -> Bool {
        declared == true
    }
}
