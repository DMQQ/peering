import Foundation

/// ``indexed(_:)`` is the 256-entry palette (`38;5;n`, `ls --color`, terminfo); ``rgb(_:_:_:)`` is `38;2;r;g;b`. The index is kept unresolved because the palette is the consumer's theme; `31` and `91` fold into 0 to 7 and 8 to 15.
public enum TerminalStyle: Sendable, Equatable, Hashable {
    case `default`
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

/// A run of characters sharing one rendition; one run per character would be thousands of views rebuilt per chunk.
public struct TerminalRun: Sendable, Equatable {
    public let text: String
    public let foreground: TerminalStyle
    public let background: TerminalStyle
    /// SGR 1: only the weight, since the bright colour is already named by ``foreground``.
    public let bold: Bool
    public let dim: Bool

    public init(
        text: String,
        foreground: TerminalStyle,
        background: TerminalStyle,
        bold: Bool,
        dim: Bool
    ) {
        self.text = text
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.dim = dim
    }
}

public struct TerminalStyledLine: Sendable, Equatable {
    public let runs: [TerminalRun]

    /// The word-matching classification, which carries failures when nothing was coloured (plain `zsh: command not found`); the consumer chooses which colour to draw.
    public let kind: TerminalTextSanitizer.Kind

    public init(runs: [TerminalRun], kind: TerminalTextSanitizer.Kind) {
        self.runs = runs
        self.kind = kind
    }

    public var text: String { runs.map(\.text).joined() }
}
