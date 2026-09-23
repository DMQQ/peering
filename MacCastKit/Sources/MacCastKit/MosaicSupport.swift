import Foundation

/// Asking a Mac to composite several of its sources into one picture, and the one question that
/// has to be answered first.
///
/// The same rule as ``PicturePause``, for a sharper reason: an older host cannot decode the
/// request at all, and an unknown `CaptureSource` case is a decode failure rather than an ignored
/// message, so the session ends rather than the picture going quiet.
public enum MosaicSupport {
    /// Whether a client may ask this Mac for a mosaic.
    ///
    /// An explicit `true` and nothing else. ``ServerHello/supportsMosaic`` is an optional additive
    /// field, so it has three states and only one of them is permission: `true` is a Mac that can
    /// build one, `nil` is a Mac built before the field existed, and `false` is a Mac that has said
    /// it will not. Nothing may read `nil` as "not false, so probably fine".
    public static func maySend(hostDeclared declared: Bool?) -> Bool {
        declared == true
    }
}
