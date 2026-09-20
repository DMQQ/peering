import Foundation
import Testing

@testable import SSHCore

/// Asking a session about files when there is no shell to ask through.
///
/// The only part of the browse path that can be tested without a server, and it is the part that
/// matters most when there is no server: a request is answered by the command loop inside the
/// connection's own task, so with no loop running it would sit in the command stream's buffer
/// holding a continuation that nothing will ever resume. That is a leak at best and a trap when
/// the stream is deallocated, so the refusal has to be immediate and it has to be a refusal.
@Suite("SSH browse without a shell")
struct SSHSessionBrowseTests {
    /// A session that has never been connected, which is the state these tests are about.
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

    /// A write goes through the same door, and it has to be tested through it.
    ///
    /// Worth a test of its own rather than assumed from the two above, because a write is the one
    /// request that changes something on the far end: a version of this that hung instead of
    /// refusing would not be a leak, it would be an edit the user believes has been saved.
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

    /// The three changes, and they are tested one at a time rather than as one because a hang in
    /// any of them looks different from here. A listing that hangs is a spinner; a **delete** that
    /// hangs is a file the user has been told nothing about and believes is gone, which is the
    /// worst thing this whole module could do quietly.
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

    /// The fact an editor's safety rests on, and the one thing about a read that can be checked
    /// without a server: whether the bytes in hand are the whole file. A file whose read was cut
    /// short is not editable and not downloadable, and both of those refusals are decided here.
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

        // The case the app's own arithmetic cannot see: a server that reported no size leaves the
        // two counts equal, so only the reader's own answer distinguishes a short file from one cut
        // off at the cap. If this ever stops being carried, the editor starts offering to save the
        // first 128 KB of people's files.
        let unknownSize = SSHFileContents(
            path: "/a",
            data: Data(repeating: 0x61, count: 131_072),
            totalBytes: 131_072,
            isTruncated: true
        )
        #expect(unknownSize.isTruncated, "equal counts are not proof of a whole file")
    }
}
