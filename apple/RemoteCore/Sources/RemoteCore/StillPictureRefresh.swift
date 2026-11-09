import Foundation

/// When a still screen's last picture is encoded again: once after a pause, as a keyframe that repairs what a lost packet left, then a few quick repeats that let the encoder spend bits on detail it skipped in motion.
public enum StillPictureRefresh {
    public static let stillnessMilliseconds = 150
    public static let repeatIntervalMilliseconds = 33
    public static let repeatCount = 8

    /// How long to wait before repeat number `index`, counting from zero. `nil` once the sequence is over.
    public static func delayMilliseconds(beforeRepeat index: Int) -> Int? {
        guard index >= 0, index < repeatCount else { return nil }
        return index == 0 ? stillnessMilliseconds : repeatIntervalMilliseconds
    }

    /// Only the first repeat is a keyframe: later ones are refinements, and a keyframe each time would spend the budget on repair.
    public static func isKeyframe(repeat index: Int) -> Bool { index == 0 }
}
