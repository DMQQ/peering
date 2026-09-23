import Foundation

/// A colour a cell can be drawn in.
///
/// Two ways of naming one, and they are not interchangeable. ``indexed(_:)`` is the 256-entry palette
/// a program reaches for with `38;5;n`, which is where `ls --color`, `git` and every terminfo entry
/// live; ``rgb(_:_:_:)`` is the 24-bit colour of `38;2;r;g;b`.
///
/// The index is kept as an index rather than resolved to the RGB it "means", because the palette is
/// the consumer's: index 1 is whatever red suits the theme the screen is drawn in, which is what makes
/// a program's own red match the one the rest of the app uses. The 16 entries a program names with
/// `31` or `91` are folded into the same space, standard into 0 to 7 and bright into 8 to 15.
public enum TerminalStyle: Sendable, Equatable, Hashable {
    /// No colour of its own: the terminal's foreground or background.
    case `default`
    /// One of the 256 indexed colours.
    case indexed(UInt8)
    /// 24-bit colour, from `38;2;r;g;b` / `48;2;r;g;b`.
    case rgb(UInt8, UInt8, UInt8)
}

/// A run of characters that share one rendition.
///
/// A row is cut into as few of them as its styling allows: a full-screen program's frame is a few
/// thousand cells, and one run per character would be a few thousand views rebuilt per chunk.
public struct TerminalRun: Sendable, Equatable {
    public let text: String
    public let foreground: TerminalStyle
    public let background: TerminalStyle
    /// SGR 1. A brighter weight of the same colour: the bright half of a two-entry palette colour is
    /// already named by ``foreground``, so this is only ever the weight.
    public let bold: Bool
    /// SGR 2, the faint half of a bright.
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

/// A line of the screen, cut into runs of one rendition each.
public struct TerminalStyledLine: Sendable, Equatable {
    public let runs: [TerminalRun]

    /// The word-matching classification, ``TerminalTextSanitizer/kind(of:)``, which is what carries a
    /// failure when nothing in the output was coloured at all. A shell prints `zsh: command not
    /// found: foo` in plain text, so a line with colours of its own and one without are both
    /// classified here; the consumer chooses whether to draw the colour it was given or this one.
    public let kind: TerminalTextSanitizer.Kind

    public init(runs: [TerminalRun], kind: TerminalTextSanitizer.Kind) {
        self.runs = runs
        self.kind = kind
    }

    /// The line as text, which is its runs joined back together.
    public var text: String { runs.map(\.text).joined() }
}
