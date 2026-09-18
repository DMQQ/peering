import Foundation

/// The path of something inside a folder.
///
/// One spelling of it for everyone who needs one — the row that opens an entry, the row that puts
/// its path on the command line, the panel that turns either into a request, and the SSH browser,
/// which resolves a symbolic link by naming the thing on the other end of it. Two of those
/// disagreeing about the join is a folder that opens next to another one.
///
/// Lifted here from ``FileBrowserPanel`` when the SSH browser became the second caller: the file
/// around it was the Mac's, and the join was never about the Mac.
///
/// A name under a directory that is not absolute is left as the bare name, because it is a name
/// and not a path — the only caller that can produce one is a browser whose folder has not been
/// resolved yet, and it does not draw a row until it has been.
public func childPath(_ name: String, of directory: String?) -> String {
    guard let directory, directory.hasPrefix("/") else { return name }
    return directory == "/" ? "/" + name : directory + "/" + name
}

/// A path written the way a shell will read it back.
///
/// Two browsers need this and they need it for the same reason: a path is data, and the line it
/// goes into is not. A folder called `My Documents` arrives as two arguments, and one called
/// `; rm -rf ~` — a legal name on every Unix, and one that reaches this app over a network —
/// arrives as a command.
///
/// Written once, and here, because two quoting rules are two chances to get an injection wrong.
/// The Mac's terminal and the SSH terminal put the same string in front of two different shells,
/// and both of them read it the same way.
public enum ShellPath {
    /// Single quotes, with the one character they cannot hold written the way the shell's own
    /// manual says to: close the quote, escape the quote, open another.
    ///
    /// Single rather than double quotes, because inside them a shell expands nothing at all — no
    /// `$`, no backticks, no history, no backslashes. Every one of those is a legal character in
    /// a file name and every one of them means something inside double quotes.
    ///
    /// One shell escapes it anyway: an *interactive* `csh` or `tcsh` expands history even inside
    /// single quotes, so a path holding a `!` is still a path holding a `!` there. Which is a
    /// reason to reach for `cd --` over `cd`, and not a reason to invent a third quoting rule for
    /// a shell nobody's login prompt has offered since 1994.
    public static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
