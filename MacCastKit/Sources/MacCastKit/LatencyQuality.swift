import Foundation

/// How a round trip reads to a person, and when it is worth saying anything at all.
///
/// The bands are the ones `ColorPalette.reading(_:)` already used, so the colour and the word share
/// one set of thresholds. The pill sits over the picture, where a figure is read as a warning even
/// when it is 90 milliseconds, so it says nothing while the connection is fine and leaves the number
/// to the expanded status bar and the Sessions tab.
public enum LatencyQuality: Sendable, Equatable, CaseIterable {
    /// Nothing to say.
    case good
    /// Worth a word, not worth an alarm.
    case fair
    /// The point at which a user starts wondering whether it is the app.
    case poor

    public static func of(milliseconds: Double) -> LatencyQuality {
        switch milliseconds {
        case ..<40: return .good
        case ..<120: return .fair
        default: return .poor
        }
    }

    /// What the collapsed pill says, or `nil` when it should say nothing: a line that is always
    /// occupied cannot be told apart from a warning.
    public var pillLabel: String? {
        switch self {
        case .good: return nil
        case .fair: return String(localized: "Slow")
        case .poor: return String(localized: "Very slow")
        }
    }

    /// The same fact as a sentence, for a reader who cannot see the pill.
    public var spokenLabel: String {
        switch self {
        case .good: return String(localized: "The connection is quick")
        case .fair: return String(localized: "The connection is a little slow")
        case .poor: return String(localized: "The connection is slow")
        }
    }
}
