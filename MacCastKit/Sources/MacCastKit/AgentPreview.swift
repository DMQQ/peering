import Foundation

extension AgentTranscript {
    /// The last thing said, plain: a card is a glance at where the conversation stands.
    public var preview: String? {
        for item in items.reversed() {
            switch item {
            case .reply(_, let text), .user(_, let text):
                if let plain = Self.plain(text) { return plain }
            default:
                continue
            }
        }
        return nil
    }

    static func plain(_ text: String) -> String? {
        let plain = text
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "#", with: "")
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return plain.isEmpty ? nil : String(plain.prefix(140))
    }
}
