import Foundation

/// The part of a long tool output worth laying out at once: a text view that holds thousands of lines stutters every frame its card animates.
public struct ToolOutputPreview: Equatable, Sendable {
    public let shown: String
    public let hiddenLines: Int

    public static let defaultLines = 40
    public static let defaultCharacters = 4000

    public init(_ text: String, maxLines: Int = defaultLines, maxCharacters: Int = defaultCharacters) {
        var end = text.startIndex
        var lines = 0
        var characters = 0
        while end < text.endIndex, lines < maxLines, characters < maxCharacters {
            if text[end] == "\n" { lines += 1 }
            end = text.index(after: end)
            characters += 1
        }
        if end == text.endIndex {
            shown = text
            hiddenLines = 0
        } else {
            shown = String(text[..<end]).trimmingCharacters(in: .newlines)
            hiddenLines = max(1, text[end...].split(separator: "\n", omittingEmptySubsequences: false).count)
        }
    }
}
