import Foundation
import Testing

@testable import RemoteCore

@Suite("Replacing a file in one move")
struct FileReplacementTests {
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
        // Compare directories: a scratch file in a temp dir can be on another volume, where rename is a copy.
        // Compared as strings: `URL ==` differs between resolvingSymlinksInPath and appendingPathComponent forms.
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
        // Resolved first so the move is onto the same volume as the real file.
        let root = try scratch()
        let realDirectory = root.appendingPathComponent("real")
        let linkDirectory = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkDirectory, withDestinationURL: realDirectory)

        let destination = linkDirectory.appendingPathComponent("script.sh")
        let staging = FileReplacement.stagingURL(for: destination, tag: "abc")

        // Resolved on both sides: `resolvingSymlinksInPath` leaves a nonexistent leaf alone.
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

        #expect(try String(contentsOf: destination, encoding: .utf8) == "new\n")
    }

    @Test("an executable stays executable")
    func commitKeepsPermissions() throws {
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
        let denied = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        #expect(FileReplacement.message(for: denied).contains("not allowed"))

        let full = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        #expect(FileReplacement.message(for: full).contains("not enough room"))

        let gone = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        #expect(FileReplacement.message(for: gone).contains("no longer there"))
    }
}
