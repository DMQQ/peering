import Foundation

/// The rate the capture stream itself should deliver while a client asks for fewer frames than the stream was started at.
public enum StreamPacing {
    /// Never above `base`: raising the request back to or past it restores the rate the stream started with, and a stream is never asked for more than the display and the encoder were set up for.
    public static func streamRate(requested: Int?, base: Int) -> Int {
        guard base > 0 else { return base }
        guard let requested, requested > 0 else { return base }
        return min(requested, base)
    }

    /// Frames per second a stream's `minimumFrameInterval` (value over timescale) asks for, or nil when it sets none.
    public static func rate(intervalValue: Int64, intervalTimescale: Int32) -> Int? {
        guard intervalValue > 0, intervalTimescale > 0 else { return nil }
        return Int((Double(intervalTimescale) / Double(intervalValue)).rounded())
    }
}
