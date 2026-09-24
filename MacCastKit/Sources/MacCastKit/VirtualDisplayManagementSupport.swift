import Foundation

/// Asking a Mac to make or remove a virtual display beyond its own settings switch, and the one
/// question that has to be answered first.
///
/// The same rule as ``MosaicSupport``: sending the command unprompted assumes a host new enough
/// to have both the command and the private display API it needs, and a client that asks a Mac
/// that never said so is a client spending a message on nothing.
public enum VirtualDisplayManagementSupport {
    /// Whether a client may ask this Mac to add or remove a virtual display.
    ///
    /// An explicit `true` and nothing else. ``ServerHello/supportsVirtualDisplayManagement`` is an
    /// optional additive field, so `nil` is a Mac built before it existed and `false` is a Mac that
    /// has said its system software cannot do this; neither is permission.
    public static func maySend(hostDeclared declared: Bool?) -> Bool {
        declared == true
    }

    /// How many displays the phone may add beyond the Mac's own switch.
    ///
    /// One number, shared by the host (which refuses past it) and the client (which hides its "add
    /// a display" row past it), so the two never quietly disagree about where the limit is. A
    /// guard against a runaway or misbehaving client rather than a promised ceiling.
    public static let maximumManagedDisplayCount = 3
}
