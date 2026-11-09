import Foundation

/// What a stream should spend its bits on at a given rate: fewer pixels and fewer frames when the budget is small, because a sharp small picture beats a blocky large one.
public enum StreamShaping {
    /// Bits per pixel per frame below which screen text visibly shimmers.
    static let minimumBitsPerPixel = 0.05
    static let lowRateKbps = 2_500
    static let lowRateFramesPerSecond = 30

    /// `nil` when the rate affords the full rate the client asked for.
    public static func framesPerSecondCeiling(bitrateKbps: Int) -> Int? {
        bitrateKbps <= lowRateKbps ? lowRateFramesPerSecond : nil
    }

    /// The linear scale, in 0.5...1, at which `nativePixels` fit the rate at `framesPerSecond` without dropping under ``minimumBitsPerPixel``.
    public static func pixelScale(bitrateKbps: Int, framesPerSecond: Int, nativePixels: Double) -> Double {
        guard nativePixels > 0, framesPerSecond > 0, bitrateKbps > 0 else { return 1 }
        let affordablePixels = Double(bitrateKbps) * 1_000 / (Double(framesPerSecond) * minimumBitsPerPixel)
        return min(max((affordablePixels / nativePixels).squareRoot(), 0.5), 1)
    }

    /// Bytes per second the encoder may emit in any one-second window: headroom over the average so a scroll's burst is shaped, not queued.
    public static func peakBytesPerSecond(averageBitsPerSecond: Int) -> Int {
        averageBitsPerSecond * 3 / 2 / 8
    }
}
