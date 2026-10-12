import Foundation

/// The random tag a phone puts in its hello so one connection can be read from both ends in analytics. It names an attempt, never a device or a person, and is new for every manual connect.
public enum SessionRef {
    public static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = generator.next() as UInt64
        return String(format: "%08x", UInt32(truncatingIfNeeded: value))
    }

    /// The Mac reads this from a hello it does not control, so anything but eight lowercase hex characters is dropped rather than forwarded.
    public static func sanitized(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count == 8, raw.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else { return nil }
        return raw
    }
}
