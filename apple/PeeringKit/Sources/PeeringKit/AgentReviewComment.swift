import Foundation

/// One remark on a file, or on a line of its diff.
public struct AgentReviewComment: Equatable, Identifiable {
    public enum Side: Equatable {
        /// The line as it is now.
        case new
        /// A line the change removed, numbered as it was.
        case old
    }

    public let id: UUID
    public let path: String
    /// Nil for a remark on the whole file.
    public let line: Int?
    public let side: Side
    /// The line's own text, so the agent can find it even after the numbers have moved.
    public let quote: String?
    public let text: String

    public init(id: UUID = UUID(), path: String, line: Int? = nil, side: Side = .new, quote: String? = nil, text: String) {
        self.id = id
        self.path = path
        self.line = line
        self.side = side
        self.quote = quote
        self.text = text
    }
}

/// Collected comments written as one prompt.
public enum AgentReviewPrompt {
    /// The host refuses a prompt over 64 KiB, so a long review stops short and says how many it left out.
    public static let maximumBytes = 60 * 1024

    public static func text(for comments: [AgentReviewComment], limit: Int = maximumBytes) -> String {
        var text = String(localized: "Please address these review comments on your changes.")
        var left = 0
        for comment in comments {
            let entry = "\n\n" + format(comment)
            if left > 0 || text.utf8.count + entry.utf8.count > limit - 200 {
                left += 1
                continue
            }
            text += entry
        }
        if left > 0 {
            text += "\n\n" + String(localized: "\(left) more comments did not fit and are not included.")
        }
        return text
    }

    public static func location(of comment: AgentReviewComment) -> String {
        guard let line = comment.line else { return comment.path }
        let place = "\(comment.path):\(line)"
        return comment.side == .old ? place + " " + String(localized: "(line removed by the change)") : place
    }

    private static func format(_ comment: AgentReviewComment) -> String {
        var lines = [location(of: comment)]
        if let quote = comment.quote?.trimmingCharacters(in: .whitespaces), !quote.isEmpty {
            lines.append("> " + String(quote.prefix(160)))
        }
        lines.append(comment.text.trimmingCharacters(in: .whitespacesAndNewlines))
        return lines.joined(separator: "\n")
    }
}
