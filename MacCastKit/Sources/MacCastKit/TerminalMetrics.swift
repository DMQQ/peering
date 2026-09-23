import Foundation

/// How a measured log becomes the size the shell at the far end is told it is.
///
/// One place, because two: the panel's log over the Mac's own login shell, and the SSH screen's
/// over a server's. They compute the same numbers from the same face, and a policy of "how wide
/// is a terminal" is the kind that drifts silently when it is written twice.
public enum TerminalMetrics {
    /// The advance width and line height of the monospaced face both logs are set in, at a size.
    ///
    /// Approximations on purpose: being one column out is invisible in a shell prompt, and the
    /// alternative is asking CoreText for metrics on every layout pass to be exact about something
    /// nobody can see.
    ///
    /// Both follow the type size, because how much of a shell fits on the screen is exactly this
    /// arithmetic and the type size is the one thing about it the user can change: at twelve points
    /// a phone held upright fits about fifty of the eighty columns a full-screen program lays out
    /// for, so the right-hand third of every line is off the edge. Nine points fits about
    /// sixty-eight of them, which is most of the way there.
    public static func cellWidth(for fontSize: CGFloat) -> CGFloat { fontSize * 0.6 }
    public static func cellHeight(for fontSize: CGFloat) -> CGFloat { fontSize * 1.2 }

    /// The type sizes the terminals offer, in points.
    ///
    /// **Tiny is the one that fits**, and it is the reason the list goes this low: a portrait phone
    /// holds eighty columns of seven-point monospaced text, which is the whole of what a
    /// full-screen program lays out for, so at that size a shell is on the screen entire rather
    /// than two-thirds of it. It is small enough that some people will not want it, which is why it
    /// is a choice and not the default.
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
    /// A phone held upright fits about fifty, and a full-screen program drawn for fifty is a broken
    /// one: Claude Code's boxes, `htop`'s meters and `vim`'s splits all assume eighty. Both logs
    /// scroll sideways already, so the floor costs a pan and buys them a canvas to lay out on.
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
