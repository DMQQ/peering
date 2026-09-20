import Foundation
import Testing

@testable import RemoteCore

@Suite("Replacing a file in one move")
struct FileReplacementTests {
    /// A folder of its own per test, so nothing here can touch a real file.
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peering-replacement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ bytes: String, to url: URL) throws {
        try Data(bytes.utf8).write(to: url)
    }

    @Test("the replacement waits beside the file it will become")
    func stagingIsBesideTheDestination() throws {
        // **The property that makes the move atomic.** A scratch file in a temporary directory is
        // on another volume on any Mac with a separate /tmp, and a rename across volumes is a
        // copy, which is neither one step nor atomic. The test is on the directory rather than on
        // the whole path because the name carries a tag that is meant to vary.
        //
        // Compared as strings rather than as URLs. `URL`'s `==` is not a comparison of two paths:
        // a URL that has been through `resolvingSymlinksInPath` compares unequal to one that names
        // the same directory and was built by `appendingPathComponent`, which is a trap rather than
        // a fact about this code.
        let root = try scratch()
        let destination = root.appendingPathComponent("script.sh")

        let staging = FileReplacement.stagingURL(for: destination, tag: "abc")

        #expect(staging.deletingLastPathComponent().path == root.resolvingSymlinksInPath().path)
        #expect(staging.lastPathComponent.hasPrefix("."))
        #expect(staging.lastPathComponent.contains("abc"))
        #expect(staging != destination)
    }

    @Test("two transfers of one path cannot share a scratch file")
    func tagsKeepScratchFilesApart() throws {
        let root = try scratch()
        let destination = root.appendingPathComponent("script.sh")

        let first = FileReplacement.stagingURL(for: destination, tag: "one")
        let second = FileReplacement.stagingURL(for: destination, tag: "two")

        #expect(first != second)
    }

    @Test("a replacement for a link is staged beside the file the link names")
    func stagingFollowsSymlinks() throws {
        // The destination is resolved before the scratch file is named, because the move has to be
        // onto the same volume as the *real* file: a link pointing at another volume would stage
        // the replacement here and move it there, and that move is a copy.
        let root = try scratch()
        let realDirectory = root.appendingPathComponent("real")
        let linkDirectory = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkDirectory, withDestinationURL: realDirectory)

        let destination = linkDirectory.appendingPathComponent("script.sh")
        let staging = FileReplacement.stagingURL(for: destination, tag: "abc")

        // Resolved on both sides, and that is not slack in the assertion. `resolvingSymlinksInPath`
        // leaves the leaf alone when the leaf does not exist, so a destination that is not there
        // yet keeps the path the client sent and the kernel resolves the directory when the file is
        // created. The claim worth holding is the physical one: the scratch file is in the
        // directory the link names, which is where the move has to happen.
        #expect(staging.deletingLastPathComponent().resolvingSymlinksInPath().path
            == realDirectory.resolvingSymlinksInPath().path)
        #expect(staging.lastPathComponent.hasPrefix("."))
    }

    @Test("the bytes land, and the size is the file's own")
    func commitWritesTheFile() throws {
        let root = try scratch()
        let destination = root.appendingPathComponent("script.sh")
        let staging = FileReplacement.stagingURL(for: destination, tag: "abc")
        try write("echo hello\n", to: staging)

        #expect(FileReplacement.commit(staging: staging, to: destination) == .written(11))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "echo hello\n")
        // And the scratch file is gone, on the success path as well as the failures.
        #expect(FileManager.default.fileExists(atPath: staging.path) == false)
    }

    @Test("an existing file is replaced, not appended to")
    func commitReplaces() throws {
        let root = try scratch()
        let destination = root.appendingPathComponent("script.sh")
        try write("old contents that are longer\n", to: destination)
        let staging = FileReplacement.stagingURL(for: destination, tag: "abc")
        try write("new\n", to: staging)

        _ = FileReplacement.commit(staging: staging, to: destination)

        // The failure this rules out is the whole reason the scratch file exists: half the old
        // contents and half the new.
        #expect(try String(contentsOf: destination, encoding: .utf8) == "new\n")
    }

    @Test("an executable stays executable")
    func commitKeepsPermissions() throws {
        // An upload that quietly dropped the mode would leave a script that no longer runs, and
        // nothing would say why.
        let root = try scratch()
        let destination = root.appendingPathComponent("script.sh")
        try write("#!/bin/sh\n", to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)

        let staging = FileReplacement.stagingURL(for: destination, tag: "abc")
        try write("#!/bin/sh\necho hi\n", to: staging)

        _ = FileReplacement.commit(staging: staging, to: destination)

        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
    }

    @Test("a folder is refused, and the scratch file is cleaned up")
    func commitRefusesAFolder() throws {
        let root = try scratch()
        let destination = root.appendingPathComponent("somewhere")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = FileReplacement.stagingURL(for: destination, tag: "abc")
        try write("not a folder\n", to: staging)

        guard case .failure(let message) = FileReplacement.commit(staging: staging, to: destination) else {
            Issue.record("a folder was written over")
            return
        }
        #expect(message.contains("folder"))
        #expect(FileManager.default.fileExists(atPath: staging.path) == false)
    }

    @Test("a scratch file the filesystem refuses yields a sentence rather than a crash")
    func permissionFailuresAreNamed() {
        // The mapping, not the filesystem: what the user is told when a write is refused is the
        // only thing about the failure they ever see.
        let denied = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        #expect(FileReplacement.message(for: denied).contains("not allowed"))

        let full = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        #expect(FileReplacement.message(for: full).contains("not enough room"))

        let gone = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        #expect(FileReplacement.message(for: gone).contains("no longer there"))
    }
}
