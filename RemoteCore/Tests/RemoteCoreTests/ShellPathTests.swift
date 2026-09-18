import Foundation
import Testing

@testable import RemoteCore

/// A path handed to a shell.
///
/// The two browsers put paths on command lines — the Mac's terminal into a login shell on the
/// Mac, the SSH terminal into a shell on a server — and those paths came from a filesystem, which
/// will hold whatever the user or a script put there. So these are about the difference between
/// naming a file and running a command, and about the four characters that decide which of the
/// two happens.
@Suite("Shell paths")
struct ShellPathTests {
    @Test("an ordinary path is quoted and nothing else happens to it")
    func plain() {
        #expect(ShellPath.quoted("/Users/dmq/Documents") == "'/Users/dmq/Documents'")
    }

    /// The one case the rule exists for. A space splits an unquoted path into two arguments, and
    /// the shell does not report an error — it runs a different command than the one meant.
    @Test("a space survives")
    func space() {
        #expect(ShellPath.quoted("/tmp/My Documents") == "'/tmp/My Documents'")
    }

    /// The other one. A single quote cannot appear inside a quoted run, so it ends the run,
    /// escapes itself, and opens another: `'`, `\'`, `'`.
    @Test("a single quote is closed, escaped and reopened")
    func singleQuote() {
        #expect(ShellPath.quoted("/tmp/it's here") == "'/tmp/it'\\''s here'")
    }

    /// Expansion, which is what single quotes are chosen for: inside them a `$` is a `$`.
    @Test("a dollar sign is not expanded")
    func dollar() {
        #expect(ShellPath.quoted("/tmp/$HOME") == "'/tmp/$HOME'")
        #expect(ShellPath.quoted("/tmp/$(rm -rf /)") == "'/tmp/$(rm -rf /)'")
    }

    /// A newline is a legal character in a file name and a command separator on a command line.
    /// Left bare it turns one path into two commands — the second of which is whatever the file
    /// is called.
    @Test("a newline is held inside the quotes")
    func newline() {
        #expect(ShellPath.quoted("/tmp/two\nlines") == "'/tmp/two\nlines'")
    }

    @Test("a backslash is not an escape")
    func backslash() {
        #expect(ShellPath.quoted("/tmp/a\\b") == "'/tmp/a\\b'")
    }

    @Test("a backtick is not substituted")
    func backtick() {
        #expect(ShellPath.quoted("/tmp/`whoami`") == "'/tmp/`whoami`'")
    }

    /// The whole of it at once, in the spelling nobody types and a script produces.
    ///
    /// Written as raw strings and joined outside the expectation, because a comparison built
    /// inside one loses the type the literal would have had — see the note on `#expect`.
    @Test("everything hostile at once stays one argument")
    func allOfIt() {
        let hostile = #"a b'c$d\e`f"# + "\n"
        let expected = #"'a b'\''c$d\e`f"# + "\n'"
        #expect(ShellPath.quoted(hostile) == expected)
    }

    /// An empty path is quoted rather than dropped: `cd -- ''` is a failure the shell reports,
    /// which is a better answer than a `cd --` that quietly goes home.
    @Test("an empty path is still an argument")
    func empty() {
        #expect(ShellPath.quoted("") == "''")
    }
}

/// Naming something inside a folder.
///
/// Two browsers join a name to the folder it was listed in, and a third caller — the SSH browser
/// resolving a symbolic link — joins one to ask the server about the far end of it. One spelling,
/// because two that disagree open the wrong folder.
@Suite("Child paths")
struct ChildPathTests {
    @Test("a folder and a name")
    func ordinary() {
        #expect(childPath("notes.txt", of: "/home/dmq") == "/home/dmq/notes.txt")
    }

    /// The root, where a plain join would produce a doubled slash. Nothing breaks if it does, and
    /// it is still wrong: the path in a breadcrumb is read by a person.
    @Test("the root is not doubled")
    func root() {
        #expect(childPath("etc", of: "/") == "/etc")
    }

    /// A browser whose folder has not been resolved yet. It draws no rows in that state, so this
    /// is a name rather than a path — which is what it is returned as.
    @Test("no folder yet is just the name")
    func unresolved() {
        #expect(childPath("notes.txt", of: nil) == "notes.txt")
    }

    @Test("a relative folder is just the name")
    func relative() {
        #expect(childPath("notes.txt", of: ".") == "notes.txt")
    }

    @Test("a name of its own that contains a slash is not treated specially")
    func nameWithSlash() {
        #expect(childPath("a/b", of: "/tmp") == "/tmp/a/b")
    }
}
