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

/// Running a file from the folder it was found in.
@Suite("Run command")
struct RunCommandTests {
    /// The ordinary case, and the two halves are both there: the `cd` so the file's own idea of
    /// "next to me" is right, and the absolute path so the line says which file ran.
    @Test("steps into the folder and names the file")
    func ordinary() {
        #expect(
            ShellPath.runCommand(for: "/Users/dmq/bin/deploy.sh")
                == "cd -- '/Users/dmq/bin' && '/Users/dmq/bin/deploy.sh'"
        )
    }

    @Test("a file at the root steps into the root")
    func atTheRoot() {
        #expect(
            ShellPath.runCommand(for: "/deploy.sh") == "cd -- '/' && '/deploy.sh'"
        )
    }

    /// A folder whose name is several words, in both places it appears. This is the whole reason
    /// the quoting exists rather than a nicety on top of it.
    @Test("a folder with a space in it stays one argument")
    func spaces() {
        #expect(
            ShellPath.runCommand(for: "/tmp/My Documents/run me.sh")
                == "cd -- '/tmp/My Documents' && '/tmp/My Documents/run me.sh'"
        )
    }

    /// The name that is a command when it is not quoted, on a file that would be run. A folder
    /// called this is a legal folder, and a listing that contains one is a listing a server can
    /// choose to send.
    @Test("a hostile folder name is quoted rather than obeyed")
    func hostileName() {
        let command = ShellPath.runCommand(for: "/tmp/; rm -rf ~/x")
        #expect(command == "cd -- '/tmp/; rm -rf ~' && '/tmp/; rm -rf ~/x'")
        // The only quotes in the line are the ones this put there, so nothing escaped the quoting.
        #expect(command.filter { $0 == "'" }.count == 4)
    }

    @Test("a name with a single quote in it survives")
    func quoteInName() {
        #expect(
            ShellPath.runCommand(for: "/tmp/it's/run.sh")
                == "cd -- '/tmp/it'\\''s' && '/tmp/it'\\''s/run.sh'"
        )
    }

    /// A bare name has no folder to step into. Not reachable from the browser today — it draws no
    /// rows until its folder has resolved — but the answer is a command rather than a `cd -- ''`.
    @Test("a bare name runs wherever the shell already is")
    func bareName() {
        #expect(ShellPath.runCommand(for: "deploy.sh") == "'deploy.sh'")
    }
}

/// Whether a listing row is something that could be run.
@Suite("Executable entries")
struct ExecutableEntryTests {
    private func entry(_ permissions: String, isDirectory: Bool = false) -> RemoteDirectoryEntry {
        RemoteDirectoryEntry(
            name: "thing",
            isDirectory: isDirectory,
            isSymlink: false,
            size: 0,
            permissions: permissions,
            modified: nil
        )
    }

    @Test("the execute bit on any of the three is enough")
    func anyTrio() {
        #expect(entry("-rwxr-xr-x").isExecutable)
        #expect(entry("----r-xr-x").isExecutable)
        #expect(entry("-------r-x").isExecutable)
        #expect(entry("-rwx------").isExecutable)
    }

    @Test("no execute bit anywhere is not executable")
    func readableOnly() {
        #expect(entry("-rw-r--r--").isExecutable == false)
        #expect(entry("-rw-------").isExecutable == false)
    }

    /// A folder always carries execute bits, because it is what lets you look inside one. It is
    /// still not a program, and the row draws a folder rather than a run button.
    @Test("a folder is not executable whatever its bits say")
    func folders() {
        #expect(entry("drwxr-xr-x", isDirectory: true).isExecutable == false)
    }

    /// A link's own mode is `lrwxrwxrwx` whether or not its target can be run, so offering to run
    /// one would be a button that fails depending on a file this listing never looked at.
    @Test("a symbolic link is not offered")
    func symlinks() {
        #expect(entry("lrwxrwxrwx").isExecutable == false)
    }

    /// `ls` prints the setuid, setgid and sticky bits *in place of* the execute character, and the
    /// lowercase spellings only appear where execute is set too — so they are execute marks, and
    /// their uppercase forms are not.
    @Test("setuid, setgid and sticky are read the way ls spells them")
    func specialBits() {
        #expect(entry("-rwsr-xr-x").isExecutable)
        #expect(entry("-rwxr-sr-x").isExecutable)
        #expect(entry("-rwxr-xr-t").isExecutable)
        #expect(entry("-rwSr--r--").isExecutable == false)
        #expect(entry("-rw-rw-r-T").isExecutable == false)
    }

    /// The `ls` fallback sends names and no modes at all, and a missing answer is a no rather than
    /// a guess. Also for a listing that something has truncated to nonsense.
    @Test("an unreadable mode string is not an executable")
    func noModeString() {
        #expect(entry("").isExecutable == false)
        #expect(entry("rwxr-xr-x").isExecutable == false)
        #expect(entry("drwxr-xr-x!").isExecutable == false)
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

/// Whether something is inside a folder.
///
/// The question a delete asks before it acts. What is being tested here is one mistake in
/// particular — comparing strings instead of components — because the wrong answer is silent and
/// hands one user's request another user's folder.
@Suite("Path containment")
struct PathContainsTests {
    @Test("a path is inside its own folder")
    func directChild() {
        #expect(pathContains("/Users/dmq/notes.txt", "/Users/dmq"))
    }

    @Test("and deeper down")
    func deeper() {
        #expect(pathContains("/Users/dmq/Documents/tax/2026.txt", "/Users/dmq"))
    }

    /// A folder contains itself. This is what makes the guard read naturally — "is this the home
    /// folder or under it" — rather than needing a separate equality test beside it.
    @Test("a folder is inside itself")
    func itself() {
        #expect(pathContains("/Users/dmq", "/Users/dmq"))
    }

    /// **The case the whole function exists for.** `/Users/dmqx` starts with `/Users/dmq` and is a
    /// different account, and a prefix comparison would say otherwise. Every other test here
    /// passes for a `hasPrefix` implementation; this one does not.
    @Test("a sibling whose name starts the same is not inside")
    func siblingPrefix() {
        #expect(pathContains("/Users/dmqx", "/Users/dmq") == false)
        #expect(pathContains("/Users/dmq-backup/notes", "/Users/dmq") == false)
    }

    @Test("something outside is not inside")
    func outside() {
        #expect(pathContains("/etc/hosts", "/Users/dmq") == false)
        #expect(pathContains("/Users", "/Users/dmq") == false)
    }

    /// The root contains everything, which is how a guard written against the home folder also
    /// covers `/` without naming it: every path is inside the root, so one test does for both.
    @Test("the root contains everything")
    func rootContainsAll() {
        #expect(pathContains("/Users/dmq", "/"))
        #expect(pathContains("/", "/"))
        #expect(pathContains("/etc", "/"))
    }

    /// The same folder named with a trailing slash is the same folder. A path built by joining a
    /// name to a folder that ended in a slash would otherwise be a different string and a
    /// different answer — and the answer would be "no", which is the unsafe direction.
    @Test("a trailing slash changes nothing")
    func trailingSlash() {
        #expect(pathContains("/Users/dmq/notes.txt", "/Users/dmq/"))
        #expect(pathContains("/Users/dmq/", "/Users/dmq"))
    }
}
