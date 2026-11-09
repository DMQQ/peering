import Foundation

/// How often the encoder inserts a keyframe on its own. Rare on purpose: a viewer that joins or loses frames asks for one, and a 5K keyframe is a burst of megabytes that shows up as stutter.
public enum KeyframeInterval {
    public static let seconds = 10
}
