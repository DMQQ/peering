import Foundation

/// How a measured log becomes the size the shell at the far end is told it is.
///
/// One place, because two: the panel's log over the Mac's own login shell, and the SSH screen's
/// over a server's. They compute the same numbers from the same face.
public enum TerminalMetrics {
    /// The advance width and line height of the monospaced face both logs are set in, at a size.
    ///
    /// Approximations on purpose: being one column out is invisible in a shell prompt, and the
    /// alternative is asking CoreText for metrics on every layout pass. Both follow the type size,
    /// which is the one thing about this arithmetic the user can change.
    public static func cellWidth(for fontSize: CGFloat) -> CGFloat { fontSize * 0.6 }
    public static func cellHeight(for fontSize: CGFloat) -> CGFloat { fontSize * 1.2 }

    /// The type sizes the terminals offer, in points.
    ///
    /// Tiny is the one that fits: a portrait phone holds eighty columns of seven-point monospaced
    /// text, which is the whole of what a full-screen program lays out for. Small enough that some
    /// people will not want it, which is why it is a choice and not the default.
    public enum TextSize: Int, CaseIterable, Identifiable {
        case tiny = 7
        case small = 9
        case regular = 12
        case large = 15

        public var id: Int { rawValue }
        public var points: CGFloat { CGFloat(rawValue) }

        public var name: String {
            switch self {
            case .tiny: return "Tiny"
            case .small: return "Small"
            case .regular: return "Default"
            case .large: return "Large"
            }
        }

        /// What the preference holds, which is the size itself rather than a case index, so a
        /// stored value that names no case still reads as a size.
        public static func named(_ points: Int) -> TextSize {
            TextSize(rawValue: points) ?? .regular
        }
    }

    /// The narrowest either shell is ever told it is, in columns.
    ///
    /// A full-screen program drawn for the fifty a portrait phone fits is a broken one: Claude
    /// Code's boxes, `htop`'s meters and `vim`'s splits all assume eighty. Both logs scroll
    /// sideways already, so the floor costs a pan and buys them a canvas to lay out on.
    public static let minimumColumns = 80

    /// And the shortest, which is only ever reached by a keyboard covering most of the screen.
    public static let minimumRows = 6

    public static func columns(forWidth width: CGFloat, fontSize: CGFloat) -> Int {
        max(minimumColumns, Int(width / cellWidth(for: fontSize)))
    }

    public static func rows(forHeight height: CGFloat, fontSize: CGFloat) -> Int {
        max(minimumRows, Int(height / cellHeight(for: fontSize)))
    }
}
