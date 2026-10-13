import Foundation

/// The loudness history a dictation waveform draws, newest last.
public struct DictationLevels: Equatable, Sendable {
    public static let barCount = 32
    /// Quieter than this is treated as silence, and the room's own noise floor sits well under it.
    public static let floorDecibels: Float = -50

    public private(set) var bars: [Float]

    public init() {
        bars = Array(repeating: 0, count: Self.barCount)
    }

    /// Maps an average power in decibels onto 0 to 1 with a curve that lifts quiet speech, since the ear reads loudness roughly logarithmically.
    public static func level(forDecibels decibels: Float) -> Float {
        guard decibels.isFinite, decibels > floorDecibels else { return 0 }
        let linear = (decibels - floorDecibels) / -floorDecibels
        return min(1, max(0, pow(linear, 1.6)))
    }

    public mutating func add(decibels: Float) {
        bars.removeFirst()
        bars.append(Self.level(forDecibels: decibels))
    }

    public mutating func clear() {
        self = DictationLevels()
    }
}

/// How spoken text joins what is already typed.
public enum DictationText {
    /// The text to type for `spoken` after `existing`: trimmed, and separated from a word before it by one space.
    public static func insertion(after existing: String, spoken: String) -> String {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let last = existing.last, !last.isWhitespace else { return trimmed }
        return " " + trimmed
    }
}

/// Notices the end of what someone meant to say: a stretch of quiet after they have spoken.
public struct DictationPause: Sendable {
    /// The level (see ``DictationLevels``) above which sound counts as speech and not room noise.
    public static let speechLevel: Float = 0.12
    public static let silenceSeconds: TimeInterval = 2

    private var lastSpeech: TimeInterval?

    public init() {}

    /// True once, when quiet has lasted long enough after speech. `time` is any steady clock in seconds.
    public mutating func observe(level: Float, at time: TimeInterval) -> Bool {
        if level >= Self.speechLevel {
            lastSpeech = time
            return false
        }
        guard let last = lastSpeech, time - last >= Self.silenceSeconds else { return false }
        lastSpeech = nil
        return true
    }
}
