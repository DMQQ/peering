import Foundation

/// One line in the host window's log.
///
/// A struct rather than a formatted string, because the window needs three things a string has
/// already thrown away: when it happened, whether it was bad, and the ability to be copied —
/// the first two to show, the third to hand to someone else.
struct HostLogEntry: Identifiable, Sendable, Equatable {
    /// How much attention a line deserves.
    ///
    /// Three cases and no more. A log with a severity ladder people have to learn is a log
    /// nobody reads; what matters at a glance is whether this is routine, surprising, or
    /// something that did not work.
    enum Level: Sendable, Equatable {
        case info
        case warning
        case failure
    }

    let id: UUID
    let at: Date
    let level: Level
    let message: String

    init(at: Date = Date(), level: Level = .info, message: String) {
        self.id = UUID()
        self.at = at
        self.level = level
        self.message = message
    }

    /// `14:32:07`, to the second.
    ///
    /// Seconds rather than minutes: the lines this log exists for are about ordering — which
    /// happened first when a session dropped — and a minute stamp cannot answer that.
    var time: String {
        Self.formatter.string(from: at)
    }

    /// Short language used by the visible activity feed. The copied log keeps the longer
    /// fixed-width words below because those are easier to scan in plain text.
    var levelName: String {
        switch level {
        case .info: return String(localized: "Event")
        case .warning: return String(localized: "Notice")
        case .failure: return String(localized: "Failed")
        }
    }

    var levelSymbol: String {
        switch level {
        case .info: return "circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

extension Array where Element == HostLogEntry {
    /// The whole log as plain text, for the pasteboard.
    ///
    /// Timestamps and a level word on each line, so a copy pasted into a message still says
    /// when each thing happened and which ones went wrong — which is the entire reason for
    /// copying it.
    var plainText: String {
        map { entry in
            let level = switch entry.level {
            case .info: "     "
            case .warning: "WARN "
            case .failure: "FAIL "
            }
            return "\(entry.time)  \(level)\(entry.message)"
        }
        .joined(separator: "\n")
    }
}
