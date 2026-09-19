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

/// Whether `path` is `other`, or is something inside it.
///
/// The question a delete has to answer before it acts, and it is asked in two places for two
/// different reasons. On the Mac it is the guard rail: a client asking to delete `/Users` is
/// asking to delete every account on the machine, and a check against `/` and the home folder
/// alone does not catch it, because `/Users` is neither. On the phone it is what tells a preview
/// it is looking at something inside the folder that just went.
///
/// **Compared by component and not by prefix**, and that is the whole of why this is a function
/// rather than a `hasPrefix` at each call site. `/Users/dmqx` begins with `/Users/dmq` and is a
/// different account; a prefix test would hand one user's delete request another user's folder.
/// Splitting on the separator and comparing whole names is the only spelling that cannot do that.
///
/// Trailing slashes are ignored on both sides, so the folder itself and the same folder named
/// with a slash are one answer. A relative path is compared as written: nothing in the app
/// produces one — every path here comes from a listing, which is absolute — and inventing a
/// resolution for one would be inventing an answer to a question nobody asked.
public func pathContains(_ path: String, _ other: String) -> Bool {
    func components(_ value: String) -> [String] {
        value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
    let outer = components(other)
    let inner = components(path)
    // Everything is inside the root, including the root, which is what makes `/` unnecessary as
    // a case of its own at either call site.
    guard !outer.isEmpty else { return true }
    guard inner.count >= outer.count else { return false }
    return Array(inner.prefix(outer.count)) == outer
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

    /// A command that runs a file, from the folder it lives in.
    ///
    /// **Two halves, and both are load-bearing.** The `cd` comes first because a script that names
    /// a file beside itself, or writes its output there, means the folder it was found in: that is
    /// what double-clicking it in the Finder does, and what a shell does when you are standing in
    /// that folder. Without it the same file run from the home folder is a different program.
    ///
    /// The path is absolute rather than `./name` so that the command line says *which* file ran.
    /// A line that only says `./deploy.sh` makes the reader hold the folder in their head to know
    /// what they just did, and the shell's own history keeps this line afterwards.
    ///
    /// `cd --` for the reason ``quoted(_:)`` gives, and both arguments quoted so that a folder
    /// called `My Documents` stays one argument and one called `; rm -rf ~` is not an argument at
    /// all. Nothing here is a new door: this string is typed into a shell the user already has,
    /// which is what a terminal is.
    public static func runCommand(for path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        // A bare name has no folder to step into, and one caller exists that could produce it — a
        // browser whose folder has not resolved yet. Running it from wherever the shell already is
        // beats a `cd` to nothing.
        guard !folder.isEmpty, folder != "." else { return quoted(path) }
        return "cd -- \(quoted(folder)) && \(quoted(path))"
    }
}
