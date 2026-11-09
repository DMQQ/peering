import Foundation

/// When a still screen's last picture is encoded again: once after a pause, then a few quick repeats, each of which lets the encoder spend bits on detail it skipped in motion. Never a forced keyframe: at 5K one is a burst of megabytes the moment the screen goes quiet, which is the stutter this exists to remove.
public enum StillPictureRefresh {
    public static let stillnessMilliseconds = 150
    public static let repeatIntervalMilliseconds = 33
    public static let repeatCount = 8

    /// How long to wait before repeat number `index`, counting from zero. `nil` once the sequence is over.
    public static func delayMilliseconds(beforeRepeat index: Int) -> Int? {
        guard index >= 0, index < repeatCount else { return nil }
        return index == 0 ? stillnessMilliseconds : repeatIntervalMilliseconds
    }
}
