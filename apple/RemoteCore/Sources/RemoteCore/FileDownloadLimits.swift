import Foundation

/// How a file or a zipped folder travels from the Mac to the phone: in pieces the phone asks for, a few at a time.
public enum FileDownloadLimits {
    /// Raw bytes per piece, the same as an upload's: JSON grows it to about 87 KB on the wire, which the authenticated channel carries.
    public static let chunkBytes = 32 * 1024

    /// Pieces asked for ahead of the ones that have arrived, so a relay's round trip is not paid once per piece.
    public static let window = 8

    /// A larger file, or a folder whose zip comes out larger, is refused rather than filling the phone.
    public static let maximumBytes: Int64 = 512 * 1024 * 1024

    /// Without an answer to a request for this long, the download ends instead of showing a progress bar that never moves.
    public static let stallSeconds: TimeInterval = 30
}
