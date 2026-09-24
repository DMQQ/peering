import Foundation

/// Telling a Mac which way the phone is held, and the one question that has to be answered first.
///
/// The same rule as ``MosaicSupport``: the command is harmless to decode on its own, but sending it
/// unprompted assumes a host new enough to do anything useful with it, and a client that reports
/// its orientation to a Mac that never asked is a client spending a message on nothing.
public enum DeviceOrientationSupport {
    /// Whether a client may report its orientation to this Mac.
    ///
    /// An explicit `true` and nothing else. ``ServerHello/supportsDeviceOrientation`` is an
    /// optional additive field, so `nil` is a Mac built before it existed and `false` is a Mac that
    /// has said it will not act on it; neither is permission.
    public static func maySend(hostDeclared declared: Bool?) -> Bool {
        declared == true
    }
}
