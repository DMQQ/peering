import Foundation

/// One spelling of the join for every caller. A name under a non-absolute directory is left bare.
public func childPath(_ name: String, of directory: String?) -> String {
    guard let directory, directory.hasPrefix("/") else { return name }
    return directory == "/" ? "/" + name : directory + "/" + name
}

/// Whether `path` is `other` or inside it; the guard rail on a Mac delete (`/Users` would delete every account, which a check on `/` and home misses). Compared by component, not prefix: `/Users/dmqx` is not inside `/Users/dmq`. Trailing slashes are ignored; paths here come from absolute listings.
public func pathContains(_ path: String, _ other: String) -> Bool {
    func components(_ value: String) -> [String] {
        value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
    let outer = components(other)
    let inner = components(path)
    // Everything is inside the root, so `/` needs no case of its own.
    guard !outer.isEmpty else { return true }
    guard inner.count >= outer.count else { return false }
    return Array(inner.prefix(outer.count)) == outer
}

/// A path written the way a shell reads it back: `My Documents` must stay one argument and `; rm -rf ~` must not become a command.
public enum ShellPath {
    /// Single quotes (nothing expands inside them), with an embedded quote written as close, escape, reopen. `csh` and `tcsh` still expand history inside single quotes, hence `cd --`.
    public static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `cd` into the folder first because scripts that name a sibling file or write output there mean their own folder. Absolute path so the line says which file ran; both arguments quoted; `cd --` as in ``quoted(_:)``.
    public static func runCommand(for path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        // A bare name has no folder to step into.
        guard !folder.isEmpty, folder != "." else { return quoted(path) }
        return "cd -- \(quoted(folder)) && \(quoted(path))"
    }
}
