import Foundation
import RemoteCore

/// A stable digest of one file's change, so a "reviewed" mark can tell when the file has moved on.
public enum AgentReviewFingerprint {
    /// FNV-1a over the kind, the counts and the diff. Swift's `Hashable` is seeded per launch, so it cannot be stored.
    public static func of(_ file: AgentChangedFile) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ text: String) {
            for byte in text.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            }
            hash = (hash ^ 0x1f) &* 0x0000_0100_0000_01b3
        }
        mix(file.kind.rawValue)
        mix("\(file.added)")
        mix("\(file.removed)")
        mix(file.diff ?? "")
        return String(hash, radix: 16)
    }
}
