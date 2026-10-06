import Foundation

/// Same rule as ``MosaicSupport``: ask only a Mac that said it can.
public enum VirtualDisplayManagementSupport {
    /// An explicit `true` and nothing else. ``ServerHello/supportsVirtualDisplayManagement`` is an
    /// optional additive field, so `nil` is a Mac built before it existed and `false` is a Mac that
    /// has said its system software cannot do this; neither is permission.
    public static func maySend(hostDeclared declared: Bool?) -> Bool {
        declared == true
    }

    /// Shared by host (refuses past it) and client (hides its add row past it) so they never disagree.
    public static let maximumManagedDisplayCount = 3
}
