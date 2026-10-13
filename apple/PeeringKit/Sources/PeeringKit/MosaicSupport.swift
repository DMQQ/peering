import Foundation

/// Asking a Mac to composite several of its sources into one picture, and the one question that
/// has to be answered first.
public enum MosaicSupport {
    /// Whether a client may ask this Mac for a mosaic.
    public static func maySend(hostDeclared declared: Bool?) -> Bool {
        declared == true
    }
}
