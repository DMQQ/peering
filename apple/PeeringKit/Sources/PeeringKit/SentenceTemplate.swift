import Foundation

/// Reads the values back out of a sentence that was built from a fixed template, so the phone can
/// recognise an English sentence from the Mac that carries a path, a name or a number.
public enum SentenceTemplate {
    /// The text each `%@` in `template` stood for, in order, or `nil` when `text` was not built from it.
    /// A template with no `%@` matches only itself and returns an empty list.
    public static func arguments(in text: String, template: String) -> [String]? {
        let pieces = template.components(separatedBy: "%@")
        guard let first = pieces.first, let last = pieces.last else { return nil }
        guard pieces.count > 1 else { return text == template ? [] : nil }
        guard text.hasPrefix(first) else { return nil }

        var rest = text.dropFirst(first.count)
        var found: [String] = []
        for separator in pieces.dropFirst().dropLast() {
            guard let range = rest.range(of: separator) else { return nil }
            found.append(String(rest[..<range.lowerBound]))
            rest = rest[range.upperBound...]
        }
        guard rest.hasSuffix(last) else { return nil }
        found.append(String(rest.dropLast(last.count)))
        return found
    }
}
