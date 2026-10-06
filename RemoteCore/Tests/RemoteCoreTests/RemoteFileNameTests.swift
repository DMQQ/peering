import Foundation
import Testing

@testable import RemoteCore

@Suite("Entry names")
struct RemoteFileNameTests {
    @Test("an ordinary name is allowed")
    func ordinary() {
        #expect(RemoteFileName.isValid("notes.txt"))
        #expect(RemoteFileName.isValid("New Folder"))
        #expect(RemoteFileName.isValid("Meeting notes 2026-09-19.md"))
    }

    /// A slash in a rename is a move: it can climb out of the folder.
    @Test("a slash is a path, not a name")
    func slash() {
        #expect(RemoteFileName.isValid("a/b") == false)
        #expect(RemoteFileName.isValid("../.ssh/authorized_keys") == false)
        #expect(RemoteFileName.isValid("/etc/passwd") == false)
        #expect(RemoteFileName.isValid("/") == false)
    }

    @Test("the two dot names are refused")
    func dots() {
        #expect(RemoteFileName.isValid(".") == false)
        #expect(RemoteFileName.isValid("..") == false)
        #expect(RemoteFileName.isValid(".gitignore"))
        #expect(RemoteFileName.isValid("..."))
    }

    @Test("nothing is not a name")
    func empty() {
        #expect(RemoteFileName.isValid("") == false)
    }

    /// Refused rather than trimmed: trimming would create a file under a name the user did not type.
    @Test("whitespace alone is not a name")
    func whitespaceOnly() {
        #expect(RemoteFileName.isValid(" ") == false)
        #expect(RemoteFileName.isValid("   ") == false)
        #expect(RemoteFileName.isValid("\t") == false)
        #expect(RemoteFileName.isValid("\n") == false)
    }

    @Test("spaces around a real name are left alone")
    func spacesAreKept() {
        #expect(RemoteFileName.isValid("My Documents"))
        #expect(RemoteFileName.isValid(" notes.txt"))
        #expect(RemoteFileName.isValid("notes.txt "))
    }

    /// The limit is in bytes, so emoji run out at a quarter of the characters ASCII does.
    @Test("length is counted in bytes rather than characters")
    func length() {
        #expect(RemoteFileName.isValid(String(repeating: "a", count: 255)))
        #expect(RemoteFileName.isValid(String(repeating: "a", count: 256)) == false)
        let emoji = String(repeating: "🔒", count: 100)
        #expect(emoji.count == 100, "the fixture is only interesting if the two counts differ")
        #expect(RemoteFileName.isValid(emoji) == false)
    }

    /// A name is never put in front of a shell; `ShellPath.quoted` does the quoting.
    @Test("characters that would matter to a shell are still legal names")
    func hostileButLegal() {
        #expect(RemoteFileName.isValid("; rm -rf ~"))
        #expect(RemoteFileName.isValid("a b c"))
        #expect(RemoteFileName.isValid("it's here"))
        #expect(RemoteFileName.isValid("$HOME"))
        #expect(RemoteFileName.isValid("two\nlines"))
    }

    /// A NUL ends a C string, so the name shown and the file opened would differ.
    @Test("a NUL is refused")
    func nul() {
        #expect(RemoteFileName.isValid("a\u{0}b") == false)
    }
}

@Suite("Available names")
struct AvailableNameTests {
    @Test("the first one in an empty folder is not numbered")
    func first() {
        #expect(RemoteFileName.available(base: "New Folder", among: []) == "New Folder")
    }

    @Test("the first one in a folder with other things in it is not numbered either")
    func firstAmongOthers() {
        #expect(
            RemoteFileName.available(base: "New Folder", among: ["notes.txt", "src"])
                == "New Folder"
        )
    }

    @Test("the second one is numbered two")
    func second() {
        #expect(
            RemoteFileName.available(base: "New Folder", among: ["New Folder"])
                == "New Folder 2"
        )
    }

    /// Counts up from two rather than past the highest number, so a freed name is reused.
    @Test("the lowest free number is used, not the next one after the highest")
    func reusesAGap() {
        let taken = ["New Folder", "New Folder 3", "New Folder 4"]
        #expect(RemoteFileName.available(base: "New Folder", among: taken) == "New Folder 2")
    }

    @Test("a run of taken names is stepped over")
    func skipsARun() {
        let taken = (1...5).map { $0 == 1 ? "New Folder" : "New Folder \($0)" }
        #expect(RemoteFileName.available(base: "New Folder", among: taken) == "New Folder 6")
    }

    /// A hand-made `New Folder 2` must not be handed out again.
    @Test("a hand-made name in the sequence is respected")
    func respectsHandMade() {
        #expect(
            RemoteFileName.available(base: "New Folder", among: ["New Folder 2"])
                == "New Folder"
        )
        #expect(
            RemoteFileName.available(base: "New Folder", among: ["New Folder", "New Folder 2"])
                == "New Folder 3"
        )
    }

    @Test("a file keeps its extension and the number goes before it")
    func extensionStaysAtTheEnd() {
        #expect(
            RemoteFileName.available(
                base: "New File",
                extension: ".txt",
                among: ["New File.txt"]
            ) == "New File 2.txt"
        )
        #expect(
            RemoteFileName.available(
                base: "New File",
                extension: ".txt",
                among: ["New File.txt", "New File 2.txt"]
            ) == "New File 3.txt"
        )
    }

    /// APFS is case-insensitive by default, so `new folder` and `New Folder` are one file on the Mac and two on most servers.
    @Test("a name differing only in case still counts as taken")
    func caseInsensitiveCollision() {
        #expect(
            RemoteFileName.available(base: "New Folder", among: ["new folder"])
                == "New Folder 2"
        )
        #expect(
            RemoteFileName.available(base: "New File", extension: ".txt", among: ["NEW FILE.TXT"])
                == "New File 2.txt"
        )
    }

    @Test("a similarly named file is a different name")
    func namesAreComparedWhole() {
        #expect(
            RemoteFileName.available(
                base: "New File",
                extension: ".txt",
                among: ["New File.txt.bak"]
            ) == "New File.txt"
        )
    }
}
