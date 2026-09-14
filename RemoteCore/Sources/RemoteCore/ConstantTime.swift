import Foundation

/// Comparison helpers that do not leak information through timing.
public enum ConstantTime {
    /// Compares two byte sequences without short-circuiting.
    ///
    /// Swift's `Data ==` and `Array ==` return as soon as they find a differing byte,
    /// so the time they take reveals how many leading bytes matched. That is exactly the
    /// signal an attacker needs to recover a secret byte by byte, so secrets — and any
    /// comparison whose inputs an attacker can influence — must use this instead.
    ///
    /// The length comparison itself short-circuits, which is fine for our uses: the
    /// values compared here are fixed-size digests and public keys, never secrets whose
    /// length is sensitive.
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
