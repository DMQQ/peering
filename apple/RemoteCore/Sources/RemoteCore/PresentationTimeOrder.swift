import Foundation

/// An encoder session wants presentation times that only go up. A refreshed still picture is stamped from the frame it repeats plus the wait, and the next real frame is stamped by the capture clock, so the two can disagree by a few milliseconds and the real one lands behind.
public enum PresentationTimeOrder {
    /// Smaller than any frame interval, larger than clock jitter.
    public static let minimumStepSeconds = 0.001

    /// `seconds` unchanged when it is later than `last`, else one step after `last`.
    public static func strictlyAfter(_ seconds: Double, last: Double?) -> Double {
        guard let last, seconds <= last else { return seconds }
        return last + minimumStepSeconds
    }
}
