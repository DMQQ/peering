import Foundation
import RemoteCore
import Testing

@testable import SSHCore

@Suite("SSH directory listings")
struct SSHDirectoryListingTests {
    private func entry(
        _ name: String,
        isDirectory: Bool = false,
        isSymlink: Bool = false,
        size: Int64 = 0
    ) -> RemoteDirectoryEntry {
        RemoteDirectoryEntry(
            name: name,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: size,
            permissions: "",
            modified: nil
        )
    }

    // MARK: - Normalising

    @Test("the two dot-entries are dropped")
    func dotEntries() {
        let normalised = SSHDirectoryListing.normalise([
            entry("."), entry(".."), entry("notes.txt"),
        ])
        #expect(normalised.entries.map(\.name) == ["notes.txt"])
    }

    @Test("folders come first, then names")
    func foldersFirst() {
        let normalised = SSHDirectoryListing.normalise([
            entry("zebra.txt"), entry("alpha", isDirectory: true),
            entry("apple.txt"), entry("beta", isDirectory: true),
        ])
        #expect(normalised.entries.map(\.name) == ["alpha", "beta", "apple.txt", "zebra.txt"])
    }

    /// `localizedStandardCompare` rather than `<`, which would put `file 10` before `file 9`.
    @Test("numbers inside names sort as numbers")
    func numericNames() {
        let normalised = SSHDirectoryListing.normalise([
            entry("file 10.txt"), entry("file 9.txt"), entry("file 100.txt"),
        ])
        #expect(normalised.entries.map(\.name) == ["file 9.txt", "file 10.txt", "file 100.txt"])
    }

    @Test("hidden names are kept, because the panel decides about those")
    func hiddenNames() {
        let normalised = SSHDirectoryListing.normalise([entry(".bashrc"), entry("readme")])
        #expect(normalised.entries.map(\.name) == [".bashrc", "readme"])
    }

    @Test("a listing longer than the cap is cut, and says so")
    func capped() {
        let many = (1...SSHDirectoryListing.maximumEntries + 1).map { entry("file \($0)") }
        let normalised = SSHDirectoryListing.normalise(many)
        #expect(normalised.entries.count == SSHDirectoryListing.maximumEntries)
        #expect(normalised.isTruncated)
    }

    @Test("a listing exactly at the cap is not called truncated")
    func exactlyAtTheCap() {
        let many = (1...SSHDirectoryListing.maximumEntries).map { entry("file \($0)") }
        #expect(SSHDirectoryListing.normalise(many).isTruncated == false)
    }

    @Test("the cut keeps the first names in order, not the first names sent")
    func cutAfterSorting() {
        var many = (1...SSHDirectoryListing.maximumEntries).map { entry("b\($0)") }
        many.insert(entry("aaa"), at: 0)
        let normalised = SSHDirectoryListing.normalise(many)
        #expect(normalised.entries.first?.name == "aaa")
        #expect(normalised.entries.count == SSHDirectoryListing.maximumEntries)
    }

    // MARK: - The one-name-per-line fallback

    /// Real output from `ls -1pA`; a space and a single quote are just characters here.
    @Test("a one-name-per-line listing reads back with folders marked")
    func plainListing() {
        let output = """
        .dotfile
        $dollar
        file with space.txt
        hidden
        it's a dir/
        """
        let entries = SSHDirectoryListing.entries(fromListing: output)
        #expect(entries.map(\.name) == [".dotfile", "$dollar", "file with space.txt", "hidden", "it's a dir"])
        #expect(entries.map(\.isDirectory) == [false, false, false, false, true])
    }

    @Test("an empty listing is empty rather than one blank row")
    func emptyListing() {
        #expect(SSHDirectoryListing.entries(fromListing: "").isEmpty)
        #expect(SSHDirectoryListing.entries(fromListing: "\n\n").isEmpty)
    }

    @Test("the fallback knows nothing it was not told")
    func fallbackHasNoAttributes() {
        let entries = SSHDirectoryListing.entries(fromListing: "notes.txt")
        #expect(entries.first?.size == 0)
        #expect(entries.first?.permissions == "")
        #expect(entries.first?.modified == nil)
        #expect(entries.first?.isSymlink == false)
    }

    /// A newline in a name is a separator in this format, so it arrives as two rows (see `SSHFileService.listCommand`).
    @Test("a name containing a newline arrives as two rows")
    func newlineInName() {
        let entries = SSHDirectoryListing.entries(fromListing: "two\nlines\n")
        #expect(entries.count == 2)
    }

    // MARK: - From attributes

    @Test("a mode word becomes the same string ls would print")
    func modeWords() {
        #expect(SSHDirectoryListing.entry(name: "a", mode: 0o100_644, size: 12, modified: nil).permissions == "-rw-r--r--")
        #expect(SSHDirectoryListing.entry(name: "a", mode: 0o040_755, size: 0, modified: nil).permissions == "drwxr-xr-x")
        #expect(SSHDirectoryListing.entry(name: "a", mode: 0o120_777, size: 9, modified: nil).permissions == "lrwxrwxrwx")
    }

    @Test("setuid, setgid and sticky replace the execute character")
    func specialBits() {
        #expect(SSHDirectoryListing.entry(name: "a", mode: 0o104_755, size: 0, modified: nil).permissions == "-rwsr-xr-x")
        #expect(SSHDirectoryListing.entry(name: "a", mode: 0o102_755, size: 0, modified: nil).permissions == "-rwxr-sr-x")
        #expect(SSHDirectoryListing.entry(name: "a", mode: 0o104_644, size: 0, modified: nil).permissions == "-rwSr--r--")
        #expect(SSHDirectoryListing.entry(name: "a", mode: 0o041_777, size: 0, modified: nil).permissions == "drwxrwxrwt")
    }

    @Test("the type bits decide what a row opens as")
    func types() {
        let folder = SSHDirectoryListing.entry(name: "a", mode: 0o040_755, size: 4_096, modified: nil)
        #expect(folder.isDirectory)
        #expect(folder.isSymlink == false)
        // A folder's size is its own entry's bytes, as `ls -l` prints; deliberately not a walk of its contents.
        #expect(folder.size == 4_096)

        let link = SSHDirectoryListing.entry(name: "a", mode: 0o120_777, size: 0, modified: nil)
        #expect(link.isSymlink)
        #expect(link.isDirectory == false)

        let fifo = SSHDirectoryListing.entry(name: "a", mode: 0o010_644, size: 0, modified: nil)
        #expect(fifo.permissions == "prw-r--r--")
    }

    @Test("attributes a server did not send are absent rather than zero")
    func missingAttributes() {
        let unknown = SSHDirectoryListing.entry(name: "a", mode: nil, size: nil, modified: nil)
        #expect(unknown.permissions == "")
        #expect(unknown.size == 0)
        #expect(unknown.isDirectory == false)
    }

    @Test("a modification date is carried through")
    func modificationDate() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = SSHDirectoryListing.entry(name: "a", mode: 0o100_644, size: 3, modified: when)
        #expect(entry.modified == when)
        #expect(entry.size == 3)
    }

    // MARK: - The command itself

    /// Pinned exactly: a server executes it. The path goes through the shared quoting rule, so a folder called `; rm -rf ~` is a folder, and `head` asks for exactly one row more than the cap so truncation is a fact, not a guess.
    @Test("the fallback command quotes the folder and caps the answer at one past the cap")
    func theCommand() {
        let expected = "command ls -1pA -- '/tmp/it'\\''s here' | command head -n 2001"
        #expect(SSHFileService.listingCommand(for: "/tmp/it's here") == expected)
    }
}
