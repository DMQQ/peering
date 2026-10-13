import Foundation
import Testing

@testable import PeeringKit

@Suite("Walking a folder to send")
struct FolderWalkTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peering-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func file(_ path: String, in root: URL, bytes: Int = 0) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(count: bytes).write(to: url)
    }

    @Test("a folder comes before the things inside it")
    func folderPrecedesItsContents() throws {
        // Entries are sent one at a time and a file cannot be written into a missing folder, so a folder must be listed before what it holds.
        let root = try scratch()
        try file("photos/one.jpg", in: root)
        try file("photos/two.jpg", in: root)

        let entries = try FolderWalk.entries(of: root, at: "/dest")

        let folder = try #require(entries.firstIndex { $0.path == "/dest/photos" })
        let first = try #require(entries.firstIndex { $0.path == "/dest/photos/one.jpg" })
        #expect(folder < first)
        #expect(entries[folder].isFolder)
    }

    @Test("nested folders are walked to the bottom")
    func nestesAreWalked() throws {
        let root = try scratch()
        try file("a/b/c/deep.txt", in: root)

        let paths = try FolderWalk.entries(of: root, at: "/dest").map(\.path)

        #expect(paths == ["/dest/a", "/dest/a/b", "/dest/a/b/c", "/dest/a/b/c/deep.txt"])
    }

    @Test("two walks of one folder produce the same list")
    func theOrderIsStable() throws {
        // The filesystem's order is not stable, so sort: failures must be reproducible.
        let root = try scratch()
        for name in ["zebra", "apple", "mango", "banana"] {
            try file(name, in: root)
        }

        let first = try FolderWalk.entries(of: root, at: "/dest").map(\.path)
        let second = try FolderWalk.entries(of: root, at: "/dest").map(\.path)

        #expect(first == second)
        #expect(first == ["/dest/apple", "/dest/banana", "/dest/mango", "/dest/zebra"])
    }

    @Test("a link is listed and skipped rather than followed")
    func linksAreSkipped() throws {
        // A symlink is an entry with an outcome rather than an omission: following it reads a file the user did not pick, and a short folder should say so.
        let root = try scratch()
        try file("real/data.txt", in: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: root.appendingPathComponent("real/data.txt")
        )

        let entries = try FolderWalk.entries(of: root, at: "/dest")
        let link = try #require(entries.first { $0.path == "/dest/link" })

        guard case .skipped = link.outcome else {
            Issue.record("a link was not skipped: \(link.outcome)")
            return
        }
        #expect(link.source == nil)
    }

    @Test("the entries carry the size, and the destination path")
    func entriesAreDescribed() throws {
        let root = try scratch()
        try file("one.txt", in: root, bytes: 1234)

        let entry = try #require(try FolderWalk.entries(of: root, at: "/dest").first)

        #expect(entry.name == "one.txt")
        #expect(entry.path == "/dest/one.txt")
        #expect(entry.bytes == 1234)
        #expect(entry.isFolder == false)
        #expect(entry.source != nil)
    }
}

@Suite("What a folder transfer reports")
struct FolderUploadTests {
    private func entry(
        _ name: String,
        isFolder: Bool = false,
        outcome: FolderUploadEntry.Outcome = .waiting
    ) -> FolderUploadEntry {
        FolderUploadEntry(
            path: "/dest/\(name)",
            name: name,
            isFolder: isFolder,
            source: isFolder ? nil : URL(fileURLWithPath: "/tmp/\(name)"),
            bytes: 100,
            outcome: outcome
        )
    }

    @Test("while it is going, the line says where it is and what it is on")
    func runningLine() {
        let upload = FolderUpload(root: "/dest", listingFolder: "/parent", entries: [
            entry("a.txt", outcome: .done),
            entry("b.txt"),
            entry("c.txt"),
        ])

        #expect(upload.line() == "Sending 1 of 3… b.txt")
    }

    @Test("the count is the files, not the folders")
    func foldersAreNotCounted() {
        // "Sent 3 of 3" for three picked files, not "Sent 4 of 5" counting the folders made for the protocol.
        var upload = FolderUpload(root: "/dest", listingFolder: "/parent", entries: [
            entry("photos", isFolder: true, outcome: .done),
            entry("a.txt", outcome: .done),
            entry("b.txt", outcome: .done),
            entry("c.txt", outcome: .done),
        ])
        upload.next = 4
        upload.isRunning = false

        #expect(upload.fileCount == 3)
        #expect(upload.line() == "Sent 3 of 3.")
    }

    @Test("a folder that could not be made is not the user's problem to read")
    func folderFailuresAreNotReported() {
        // A folder is the shape the files need, not a chosen item, so made-or-existing is not reported; one that cannot be made still fails every file inside, named.
        var upload = FolderUpload(root: "/dest", listingFolder: "/parent", entries: [
            entry("photos", isFolder: true, outcome: .failed("Something with that name is already there.")),
            entry("a.txt", outcome: .done),
        ])
        upload.next = 2
        upload.isRunning = false

        #expect(upload.problems.isEmpty)
        #expect(upload.line() == "Sent 1 of 1.")
    }

    @Test("the failures are named, up to a few")
    func failuresAreNamed() {
        var upload = FolderUpload(root: "/dest", listingFolder: "/parent", entries: [
            entry("a.txt", outcome: .done),
            entry("b.txt", outcome: .failed("Not allowed to write that.")),
            entry("c.txt", outcome: .skipped("A link to somewhere else, which is not copied.")),
            entry("d.txt", outcome: .failed("Too large.")),
            entry("e.txt", outcome: .failed("Gone.")),
        ])
        upload.next = 5
        upload.isRunning = false

        // Named so the user need not hunt for which three; capped because the line has one row.
        #expect(upload.line() == "Sent 1 of 5. Could not send b.txt, c.txt, d.txt and 1 more.")
        #expect(upload.sent == 1)
    }
}
