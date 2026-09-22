import Foundation

/// How a round trip reads to a person, and when it is worth saying anything at all.
///
/// **A number is a diagnosis, and a diagnosis is not what a glance is for.** A session's round trip
/// appears in the pill that sits over the picture, which is the one place in the app a user reads
/// without deciding to: a figure there is read as a warning even when it is 90 milliseconds, which
/// is a perfectly usable session. So the pill says nothing while the connection is fine, says a word
/// when it is not, and leaves the figure to the two places somebody has chosen to look at it: the
/// expanded status bar, and the Sessions tab.
///
/// **The bands are the ones the colour already used**, moved here from `ColorPalette.reading(_:)`
/// so there is one set of thresholds rather than a colour's opinion and a word's opinion. What
/// counts as poor is a judgement about remote desktops: under 40 ms of round trip is
/// indistinguishable from local, under 120 is a session you would not describe as slow, and past
/// that the pointer starts arriving after the finger.
public enum LatencyQuality: Sendable, Equatable, CaseIterable {
    /// Nothing to say. This is the state a good session is in.
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

    /// What the collapsed pill says, or `nil` when it should say nothing.
    ///
    /// The pill is the only place this is used, and the emptiness is the feature: a session that
    /// is behaving normally has nothing to report, and a line that is always occupied by a number
    /// is a line nobody can tell apart from a warning.
    public var pillLabel: String? {
        switch self {
        case .good: return nil
        case .fair: return "Slow"
        case .poor: return "Very slow"
        }
    }

    /// The same fact as a sentence, for a reader who cannot see the pill.
    public var spokenLabel: String {
        switch self {
        case .good: return "The connection is quick"
        case .fair: return "The connection is a little slow"
        case .poor: return "The connection is slow"
        }
    }
}
