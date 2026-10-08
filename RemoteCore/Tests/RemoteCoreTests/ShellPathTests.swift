import Foundation
import Testing

@testable import RemoteCore

@Suite("Shell paths")
struct ShellPathTests {
    @Test("an ordinary path is quoted and nothing else happens to it")
    func plain() {
        #expect(ShellPath.quoted("/Users/dmq/Documents") == "'/Users/dmq/Documents'")
    }

    /// A space splits an unquoted path into two arguments and the shell runs a different command without an error.
    @Test("a space survives")
    func space() {
        #expect(ShellPath.quoted("/tmp/My Documents") == "'/tmp/My Documents'")
    }

    /// A single quote ends a quoted run, so it is closed, escaped and reopened: `'`, `\'`, `'`.
    @Test("a single quote is closed, escaped and reopened")
    func singleQuote() {
        #expect(ShellPath.quoted("/tmp/it's here") == "'/tmp/it'\\''s here'")
    }

    @Test("a dollar sign is not expanded")
    func dollar() {
        #expect(ShellPath.quoted("/tmp/$HOME") == "'/tmp/$HOME'")
        #expect(ShellPath.quoted("/tmp/$(rm -rf /)") == "'/tmp/$(rm -rf /)'")
    }

    /// A newline is a legal file name character and a command separator, so left bare it turns one path into two commands.
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

    /// Raw strings joined outside the expectation: a comparison built inside `#expect` loses the literal's type.
    @Test("everything hostile at once stays one argument")
    func allOfIt() {
        let hostile = #"a b'c$d\e`f"# + "\n"
        let expected = #"'a b'\''c$d\e`f"# + "\n'"
        #expect(ShellPath.quoted(hostile) == expected)
    }

    /// An empty path is quoted rather than dropped: `cd -- ''` fails loudly where `cd --` quietly goes home.
    @Test("an empty path is still an argument")
    func empty() {
        #expect(ShellPath.quoted("") == "''")
    }
}

@Suite("Run command")
struct RunCommandTests {
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

    @Test("a folder with a space in it stays one argument")
    func spaces() {
        #expect(
            ShellPath.runCommand(for: "/tmp/My Documents/run me.sh")
                == "cd -- '/tmp/My Documents' && '/tmp/My Documents/run me.sh'"
        )
    }

    /// A folder name that is a command when unquoted: a listing can contain one.
    @Test("a hostile folder name is quoted rather than obeyed")
    func hostileName() {
        let command = ShellPath.runCommand(for: "/tmp/; rm -rf ~/x")
        #expect(command == "cd -- '/tmp/; rm -rf ~' && '/tmp/; rm -rf ~/x'")
        #expect(command.filter { $0 == "'" }.count == 4)
    }

    @Test("a name with a single quote in it survives")
    func quoteInName() {
        #expect(
            ShellPath.runCommand(for: "/tmp/it's/run.sh")
                == "cd -- '/tmp/it'\\''s' && '/tmp/it'\\''s/run.sh'"
        )
    }

    /// A bare name has no folder to step into; the answer is a command rather than `cd -- ''`.
    @Test("a bare name runs wherever the shell already is")
    func bareName() {
        #expect(ShellPath.runCommand(for: "deploy.sh") == "'deploy.sh'")
    }
}

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

    /// A folder always carries execute bits but is not a program.
    @Test("a folder is not executable whatever its bits say")
    func folders() {
        #expect(entry("drwxr-xr-x", isDirectory: true).isExecutable == false)
    }

    /// A link's own mode is `lrwxrwxrwx` whether or not its target runs, so it is never offered.
    @Test("a symbolic link is not offered")
    func symlinks() {
        #expect(entry("lrwxrwxrwx").isExecutable == false)
    }

    /// `ls` prints setuid, setgid and sticky in place of the execute character; lowercase forms imply execute, uppercase do not.
    @Test("setuid, setgid and sticky are read the way ls spells them")
    func specialBits() {
        #expect(entry("-rwsr-xr-x").isExecutable)
        #expect(entry("-rwxr-sr-x").isExecutable)
        #expect(entry("-rwxr-xr-t").isExecutable)
        #expect(entry("-rwSr--r--").isExecutable == false)
        #expect(entry("-rw-rw-r-T").isExecutable == false)
    }

    /// The `ls` fallback sends no modes, and a missing answer is a no.
    @Test("an unreadable mode string is not an executable")
    func noModeString() {
        #expect(entry("").isExecutable == false)
        #expect(entry("rwxr-xr-x").isExecutable == false)
        #expect(entry("drwxr-xr-x!").isExecutable == false)
    }
}

@Suite("Child paths")
struct ChildPathTests {
    @Test("a folder and a name")
    func ordinary() {
        #expect(childPath("notes.txt", of: "/home/dmq") == "/home/dmq/notes.txt")
    }

    /// The root, where a plain join would double the slash in a breadcrumb.
    @Test("the root is not doubled")
    func root() {
        #expect(childPath("etc", of: "/") == "/etc")
    }

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

/// Compares components, not strings: a wrong answer here is silent and hands one user's request another user's folder.
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

    @Test("a folder is inside itself")
    func itself() {
        #expect(pathContains("/Users/dmq", "/Users/dmq"))
    }

    /// `/Users/dmqx` starts with `/Users/dmq` but is another account; only a component comparison gets this right.
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

    @Test("the root contains everything")
    func rootContainsAll() {
        #expect(pathContains("/Users/dmq", "/"))
        #expect(pathContains("/", "/"))
        #expect(pathContains("/etc", "/"))
    }

    /// A trailing slash is the same folder; a different string would answer "no", the unsafe direction.
    @Test("a trailing slash changes nothing")
    func trailingSlash() {
        #expect(pathContains("/Users/dmq/notes.txt", "/Users/dmq/"))
        #expect(pathContains("/Users/dmq/", "/Users/dmq"))
    }
}
