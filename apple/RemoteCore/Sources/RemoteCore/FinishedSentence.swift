import Foundation

/// The English sentence a Mac sends when a command returns to the prompt, read back into its parts so the phone can write it in its own language.
public struct FinishedSentence: Equatable, Sendable {
    public enum Subject: Equatable, Sendable {
        case command(String)
        case terminal(name: String)
    }

    public let subject: Subject
    /// The duration text as the Mac wrote it.
    public let duration: String
    /// The duration in seconds when `duration` is the English form `spokenDuration` writes.
    public let seconds: TimeInterval?

    private static let infix = "\u{201D} finished after "

    public init?(parsing text: String) {
        guard text.hasSuffix(".") else { return nil }
        let body = text.dropLast()
        guard let split = body.range(of: Self.infix, options: .backwards) else { return nil }
        let subjectText = body[..<split.lowerBound]
        let duration = String(body[split.upperBound...])
        guard !duration.isEmpty else { return nil }

        if subjectText.hasPrefix("Terminal \u{201C}") {
            subject = .terminal(name: String(subjectText.dropFirst("Terminal \u{201C}".count)))
        } else if subjectText.hasPrefix("\u{201C}") {
            subject = .command(String(subjectText.dropFirst()))
        } else {
            return nil
        }
        self.duration = duration
        seconds = TerminalCommandFinishDetector.seconds(fromEnglishSpokenDuration: duration)
    }
}
