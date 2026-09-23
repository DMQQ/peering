import Foundation

/// How a measured log becomes the size the shell at the far end is told it is.
///
/// One place, because two: the panel's log over the Mac's own login shell, and the SSH screen's
/// over a server's. They compute the same numbers from the same face, and a policy of "how wide
/// is a terminal" is the kind that drifts silently when it is written twice.
public enum TerminalMetrics {
    /// The advance width and line height of the 12-point monospaced face both logs are set in.
    ///
    /// Approximations on purpose: being one column out is invisible in a shell prompt, and the
    /// alternative is asking CoreText for metrics on every layout pass to be exact about something
    /// nobody can see.
    public static let cellWidth: CGFloat = 7.2
    public static let cellHeight: CGFloat = 14.4

    /// The narrowest either shell is ever told it is, in columns.
    ///
    /// A phone held upright fits about fifty, and a full-screen program drawn for fifty is a broken
    /// one: Claude Code's boxes, `htop`'s meters and `vim`'s splits all assume eighty. Both logs
    /// scroll sideways already, so the floor costs a pan and buys them a canvas to lay out on.
    public static let minimumColumns = 80

    /// And the shortest, which is only ever reached by a keyboard covering most of the screen.
    public static let minimumRows = 6

    public static func columns(forWidth width: CGFloat) -> Int {
        max(minimumColumns, Int(width / cellWidth))
    }

    public static func rows(forHeight height: CGFloat) -> Int {
        max(minimumRows, Int(height / cellHeight))
    }
}
