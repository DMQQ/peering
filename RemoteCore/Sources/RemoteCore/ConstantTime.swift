import Foundation

/// Comparison helpers that do not leak information through timing.
public enum ConstantTime {
    /// Compares two byte sequences without short-circuiting.
    ///
    /// `Data ==` returns as soon as it finds a differing byte, so its timing reveals how many
    /// leading bytes matched. Secrets, and any comparison whose inputs an attacker can influence,
    /// must use this instead. The length check here short-circuits, which is fine: the values
    /// compared are fixed-size digests and public keys, never secrets whose length is sensitive.
    public static func equals<A: ContiguousBytes, B: ContiguousBytes>(_ a: A, _ b: B) -> Bool {
        let lhs = a.withUnsafeBytes { Array($0) }
        let rhs = b.withUnsafeBytes { Array($0) }
        guard lhs.count == rhs.count else { return false }

        var difference: UInt8 = 0
        for i in 0..<lhs.count {
            difference |= lhs[i] ^ rhs[i]
        }
        return difference == 0
    }
}
