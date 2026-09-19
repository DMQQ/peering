import Foundation
import Testing

@testable import RemoteCore

/// What a file may be called.
///
/// Both ends hold this rule and both ends ask it: the phone when it is about to make something,
/// and the machine when it is about to make it. So these are about the difference between a name
/// and a path, and about the two names every filesystem already means something by.
@Suite("Entry names")
struct RemoteFileNameTests {
    @Test("an ordinary name is allowed")
    func ordinary() {
        #expect(RemoteFileName.isValid("notes.txt"))
        #expect(RemoteFileName.isValid("New Folder"))
        #expect(RemoteFileName.isValid("Meeting notes 2026-09-19.md"))
    }

    /// A name is not a path, and this is the whole of why the distinction is written down rather
    /// than assumed. A slash in a rename is a move: it can climb out of the folder, and it can
    /// land somewhere the user has no idea they are writing to.
    @Test("a slash is a path, not a name")
    func slash() {
        #expect(RemoteFileName.isValid("a/b") == false)
        #expect(RemoteFileName.isValid("../.ssh/authorized_keys") == false)
        #expect(RemoteFileName.isValid("/etc/passwd") == false)
        // Even one on its own, which is the root and a folder and not a file.
        #expect(RemoteFileName.isValid("/") == false)
    }

    /// The two names every filesystem in existence already answers to. A rename to `..` is a
    /// request to name something after its own parent, and nothing good follows from allowing it.
    @Test("the two dot names are refused")
    func dots() {
        #expect(RemoteFileName.isValid(".") == false)
        #expect(RemoteFileName.isValid("..") == false)
        // And the ordinary names that merely start with a dot are not, because a hidden file is a
        // file and `.gitignore` is a name people type on purpose.
        #expect(RemoteFileName.isValid(".gitignore"))
        #expect(RemoteFileName.isValid("..."))
    }

    @Test("nothing is not a name")
    func empty() {
        #expect(RemoteFileName.isValid("") == false)
    }

    /// A name of nothing but spaces is legal on every Unix and a file nobody can find: it draws as
    /// a blank row in a list, and there is nothing to aim at to rename it back. Refused rather
    /// than tidied, because trimming it here would create a file under a name the user did not
    /// type and cannot see coming.
    @Test("whitespace alone is not a name")
    func whitespaceOnly() {
        #expect(RemoteFileName.isValid(" ") == false)
        #expect(RemoteFileName.isValid("   ") == false)
        #expect(RemoteFileName.isValid("\t") == false)
        #expect(RemoteFileName.isValid("\n") == false)
    }

    /// And the other side of that rule, which is the one that would break if the trim were done
    /// rather than tested: a name that merely contains spaces is a name.
    @Test("spaces around a real name are left alone")
    func spacesAreKept() {
        #expect(RemoteFileName.isValid("My Documents"))
        #expect(RemoteFileName.isValid(" notes.txt"))
        #expect(RemoteFileName.isValid("notes.txt "))
    }

    /// The limit is in bytes, which is the unit the filesystem counts in, so a name of emoji runs
    /// out at a quarter of the characters a name of ASCII does.
    @Test("length is counted in bytes rather than characters")
    func length() {
        #expect(RemoteFileName.isValid(String(repeating: "a", count: 255)))
        #expect(RemoteFileName.isValid(String(repeating: "a", count: 256)) == false)
        // 100 emoji is 400 bytes: comfortably under the character limit and well over the byte one.
        let emoji = String(repeating: "🔒", count: 100)
        #expect(emoji.count == 100, "the fixture is only interesting if the two counts differ")
        #expect(RemoteFileName.isValid(emoji) == false)
    }

    /// Everything a shell would care about is legal in a name, because a name is never put in
    /// front of a shell — the one place a path becomes a command line is `ShellPath.quoted`, and
    /// that is what quotes it.
    @Test("characters that would matter to a shell are still legal names")
    func hostileButLegal() {
        #expect(RemoteFileName.isValid("; rm -rf ~"))
        #expect(RemoteFileName.isValid("a b c"))
        #expect(RemoteFileName.isValid("it's here"))
        #expect(RemoteFileName.isValid("$HOME"))
        #expect(RemoteFileName.isValid("two\nlines"))
    }

    /// A NUL ends a C string, so a name holding one names something other than what is on screen
    /// — the file the user sees and the file that is opened would be two different files.
    @Test("a NUL is refused")
    func nul() {
        #expect(RemoteFileName.isValid("a\u{0}b") == false)
    }
}

/// Picking a name nothing is using.
@Suite("Available names")
struct AvailableNameTests {
    @Test("the first one in an empty folder is not numbered")
    func first() {
        #expect(RemoteFileName.available(base: "New Folder", among: []) == "New Folder")
    }

    /// The first one made should not announce that it is the first. This is the whole reason the
    /// unsuffixed name is tried before any number is.
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

    /// The reason this counts up from two rather than measuring the highest number present: a
    /// folder somebody tidied should hand the freed name out again, not leave a permanent gap.
    @Test("the lowest free number is used, not the next one after the highest")
    func reusesAGap() {
        let taken = ["New Folder", "New Folder 3", "New Folder 4"]
        #expect(RemoteFileName.available(base: "New Folder", among: taken) == "New Folder 2")
    }

    /// And it does not just count how many there are: two names that happen to be taken in the
    /// middle still have to be stepped over.
    @Test("a run of taken names is stepped over")
    func skipsARun() {
        let taken = (1...5).map { $0 == 1 ? "New Folder" : "New Folder \($0)" }
        #expect(RemoteFileName.available(base: "New Folder", among: taken) == "New Folder 6")
    }

    /// The case that matters most, because it is a name a person chose: a folder somebody has
    /// already made a `New Folder 2` in by hand must not have it handed out again.
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

    /// Where the number goes, which is the thing a naive implementation gets wrong: the file is
    /// still a `.txt`, because that is what anything reading extensions looks at.
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

    /// **The one that would otherwise produce a sentence the user cannot explain.** APFS is
    /// case-insensitive by default, so `new folder` and `New Folder` are one file on the Mac and
    /// two on most servers. Folding costs a number in a folder where the case differs and saves
    /// the far more confusing outcome: being told that the name you just watched the app choose
    /// is already taken.
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

    /// The comparison is against the whole name, so a `New Folder` that is really a folder is not
    /// confused with one that is a file called `New Folder.txt` — the two are different names and
    /// both can exist.
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
