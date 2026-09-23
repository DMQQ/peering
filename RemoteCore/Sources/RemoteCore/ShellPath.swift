import Foundation

/// The path of something inside a folder.
///
/// One spelling of the join for every caller that needs one, so two of them cannot disagree about
/// it and open a folder next to the wrong one.
///
/// A name under a directory that is not absolute is left as the bare name, because it is a name
/// and not a path.
public func childPath(_ name: String, of directory: String?) -> String {
    guard let directory, directory.hasPrefix("/") else { return name }
    return directory == "/" ? "/" + name : directory + "/" + name
}

/// Whether `path` is `other`, or is something inside it.
///
/// The question a delete answers before it acts, and the guard rail on the Mac: a client asking to
/// delete `/Users` is asking to delete every account on the machine, and a check against `/` and
/// the home folder alone does not catch it.
///
/// Compared by component and not by prefix: `/Users/dmqx` begins with `/Users/dmq` and is a
/// different account, so a prefix test would hand one user's delete request another user's folder.
///
/// Trailing slashes are ignored on both sides. A relative path is compared as written: every path
/// here comes from a listing, which is absolute.
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
/// A path is data, and the line it goes into is not: a folder called `My Documents` arrives as two
/// arguments, and one called `; rm -rf ~` arrives as a command.
///
/// Written once, because two quoting rules are two chances to get an injection wrong.
public enum ShellPath {
    /// Single quotes, with the one character they cannot hold written the way the shell's own
    /// manual says to: close the quote, escape the quote, open another.
    ///
    /// Single rather than double quotes, because inside them a shell expands nothing: no `$`, no
    /// backticks, no history, no backslashes.
    ///
    /// An interactive `csh` or `tcsh` expands history even inside single quotes, which is a reason
    /// to reach for `cd --` over `cd`.
    public static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A command that runs a file, from the folder it lives in.
    ///
    /// The `cd` comes first because a script that names a file beside itself, or writes its output
    /// there, means the folder it was found in; without it the same file run from the home folder
    /// is a different program.
    ///
    /// The path is absolute rather than `./name` so that the command line says which file ran, and
    /// both arguments are quoted so a folder called `My Documents` stays one argument.
    /// `cd --` for the reason ``quoted(_:)`` gives.
    public static func runCommand(for path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        // A bare name has no folder to step into, and running it from wherever the shell already is
        // beats a `cd` to nothing.
        guard !folder.isEmpty, folder != "." else { return quoted(path) }
        return "cd -- \(quoted(folder)) && \(quoted(path))"
    }
}
