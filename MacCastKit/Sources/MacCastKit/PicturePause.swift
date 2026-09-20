import Foundation

/// Asking a Mac to stop sending the picture, and the one question that has to be answered first.
///
/// See ``RemoteCommand/setVideoEnabled(_:)`` for why the command exists at all. This is the rule
/// for when it may be sent, which is small and has one way of being wrong that costs a session.
public enum PicturePause {
    /// Whether a client may ask this Mac to pause.
    ///
    /// **An explicit `true` and nothing else**, which is the whole reason this is a function rather
    /// than a `Bool` on the hello. ``ServerHello/supportsVideoPause`` is an optional additive field,
    /// so it has three states and only one of them is permission:
    ///
    /// - `true` is a Mac that has heard the question and can take the command.
    /// - `nil` is a Mac built before the field existed. It has never heard the question, and an
    ///   unknown command is a decode failure **in the middle of a session** rather than a feature
    ///   that quietly does not work. Sending to it would trade a working picture on a second Mac
    ///   for a dropped session on this one.
    /// - `false` is a Mac that knows about the command and has said it will not take it.
    ///
    /// The failure mode this rules out is the one worth naming: `nil` read as "not false, so
    /// probably fine" is the natural mistake, and it is invisible until two Macs are open at once
    /// and one of them is old.
    public static func mayAsk(hostDeclared declared: Bool?) -> Bool {
        declared == true
    }
}
