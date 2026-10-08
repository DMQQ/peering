import Foundation

public enum ConstantTime {
    /// `Data ==` short-circuits and leaks timing, so use this for secrets. The length check short-circuits too, which is fine for fixed-size digests and keys.
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
