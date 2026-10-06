import Foundation

/// How a round trip reads to a person, and when it is worth saying anything at all.
public enum LatencyQuality: Sendable, Equatable, CaseIterable {
    case good
    case fair
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
