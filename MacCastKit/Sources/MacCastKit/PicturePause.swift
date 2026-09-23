import Foundation

/// Asking a Mac to stop sending the picture, and the one question that has to be answered first.
///
/// See ``RemoteCommand/setVideoEnabled(_:)`` for why the command exists at all.
public enum PicturePause {
    /// Whether a client may ask this Mac to pause.
    ///
    /// An explicit `true` and nothing else. ``ServerHello/supportsVideoPause`` is an optional
    /// additive field, so it has three states and only one of them is permission: `true` is a Mac
    /// that can take the command, `false` one that has said it will not, and `nil` a Mac built
    /// before the field existed, where the unknown command is a decode failure in the middle of a
    /// session rather than a feature that quietly does not work.
    public static func mayAsk(hostDeclared declared: Bool?) -> Bool {
        declared == true
    }
}
