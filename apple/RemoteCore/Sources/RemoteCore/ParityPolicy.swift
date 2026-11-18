import Foundation

/// How many data chunks one parity chunk covers, chosen from the loss the viewer measured: a clean link should not pay a tenth of its bytes for protection it does not use, and a lossy one needs more than a tenth.
public enum ParityPolicy {
    public static let allowedGroups = 3...32

    public static func group(forLoss loss: Double) -> Int {
        switch loss {
        case ..<0.005: return 20
        case ..<0.02: return VideoChunk.parityGroupSize
        case ..<0.05: return 6
        default: return 4
        }
    }

    /// The figure arrives off the wire, so the sender clamps it rather than trusting the viewer.
    public static func clamped(_ requested: Int) -> Int {
        min(max(requested, allowedGroups.lowerBound), allowedGroups.upperBound)
    }
}
