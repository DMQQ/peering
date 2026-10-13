import Foundation

/// Limits on zipping a folder for a phone: the disk has to hold the result before it starts, and the zip is stopped once it passes the largest file the app moves.
public enum ArchiveBudget {
    /// Kept free beyond the zip itself, so filling the disk to the byte is not how this ends.
    public static let reserveBytes: Int64 = 512 * 1024 * 1024

    public static func hasRoom(freeBytes: Int64, cap: Int64) -> Bool {
        freeBytes >= cap + reserveBytes
    }

    public static func mustStop(archiveBytes: Int64, cap: Int64) -> Bool {
        archiveBytes > cap
    }
}
