import Foundation
import Testing

@testable import SSHCore

/// With no shell, a request would sit in the command stream's buffer holding a continuation nothing resumes (a trap on dealloc), so the refusal must be immediate.
@Suite("SSH browse without a shell")
struct SSHSessionBrowseTests {
    private func orphan() -> SSHSession {
        SSHSession(
            host: SSHHost(name: "Nowhere", hostname: "127.0.0.1", port: 1, username: "nobody"),
            credential: .password("not a password")
        ) { _ in true }
    }

    private func refusal(_ work: () async throws -> Void) async -> SSHSessionError? {
        do {
            try await work()
            return nil
        } catch let error as SSHSessionError {
            return error
        } catch {
            return .transport(String(describing: error))
        }
    }

    @Test("a listing with nothing attached comes back rather than waiting")
    func listRefused() async {
        let error = await refusal { _ = try await self.orphan().listDirectory(at: ".") }
        guard case .notConnected = error else {
            Issue.record("expected notConnected, got \(String(describing: error))")
            return
        }
    }

    @Test("so does a preview")
    func previewRefused() async {
        let error = await refusal { _ = try await self.orphan().readFile(at: "/etc/hosts") }
        guard case .notConnected = error else {
            Issue.record("expected notConnected, got \(String(describing: error))")
            return
        }
    }

    /// A write is the one request that changes the far end: hanging instead of refusing would leave an edit the user believes was saved.
    @Test("and a write, which is the one that must never look like it worked")
    func writeRefused() async {
        let error = await refusal {
            _ = try await self.orphan().writeFile(Data("new contents".utf8), to: "/etc/hosts")
        }
        guard case .notConnected = error else {
            Issue.record("expected notConnected, got \(String(describing: error))")
            return
        }
    }

    /// Tested one at a time because a hang looks different in each: a hung delete is a file the user believes is gone.
    @Test("a delete with nothing attached comes back rather than waiting")
    func deleteRefused() async {
        let error = await refusal {
            _ = try await self.orphan().change(.delete(path: "/home/someone/notes.txt"))
        }
        guard case .notConnected = error else {
            Issue.record("expected notConnected, got \(String(describing: error))")
            return
        }
    }

    @Test("and so does a rename")
    func renameRefused() async {
        let error = await refusal {
            _ = try await self.orphan().change(
                .rename(path: "/home/someone/notes.txt", to: "meeting notes.txt")
            )
        }
        guard case .notConnected = error else {
            Issue.record("expected notConnected, got \(String(describing: error))")
            return
        }
    }

    @Test("and a creation")
    func createRefused() async {
        let error = await refusal {
            _ = try await self.orphan().change(
                .create(path: "/home/someone/New Folder", kind: .folder)
            )
        }
        guard case .notConnected = error else {
            Issue.record("expected notConnected, got \(String(describing: error))")
            return
        }
    }

    /// Whether the bytes in hand are the whole file: a read cut short is neither editable nor downloadable.
    @Test("contents know whether they are the whole file")
    func truncationIsCarried() {
        let complete = SSHFileContents(path: "/a", data: Data("abc".utf8), totalBytes: 3)
        #expect(!complete.isTruncated, "three bytes of three is the whole thing")

        let cutShort = SSHFileContents(
            path: "/a",
            data: Data(repeating: 0x61, count: 131_072),
            totalBytes: 900_000,
            isTruncated: true
        )
        #expect(cutShort.isTruncated)

        // A server that reported no size leaves the two counts equal, so only the reader's own answer tells a short file from one cut at the cap; losing it would offer to save the first 128 KB of files.
        let unknownSize = SSHFileContents(
            path: "/a",
            data: Data(repeating: 0x61, count: 131_072),
            totalBytes: 131_072,
            isTruncated: true
        )
        #expect(unknownSize.isTruncated, "equal counts are not proof of a whole file")
    }
}
