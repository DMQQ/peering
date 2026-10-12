import Citadel
import Crypto
import Foundation
import NIO
import NIOFoundationCompat
import NIOSSH
import RemoteCore
import os

extension SSHSession {
    // MARK: - Files

    /// SFTP where the server offers it, a one-off `ls` where it does not (see ``SSHFileService``). Throws ``SSHSessionError/notConnected`` with no shell, and ``SSHSessionError/browse(_:)`` when the server said no. The answer carries the absolute path because the first request names none.
    public func listDirectory(at path: String) async throws -> SSHDirectory {
        guard case .listing(let directory) = try await browse(.list, at: path) else {
            throw SSHSessionError.browse("The server answered a listing request with a file.")
        }
        return directory
    }

    public func readFile(at path: String) async throws -> SSHFileContents {
        guard case .contents(let contents) = try await browse(.preview, at: path) else {
            throw SSHSessionError.browse("The server answered a file request with a folder.")
        }
        return contents
    }

    /// The whole file, not a patch (see ``SSHBrowseRequest/Kind/write(contents:)``): the editor enforces it by refusing to open a file whose read was cut short. Answers with contents so the caller shows the size the server actually holds.
    public func writeFile(_ contents: Data, to path: String) async throws -> SSHFileContents {
        guard case .written(let written) = try await browse(.write(contents: contents), at: path)
        else {
            throw SSHSessionError.browse("The server answered a write with something else.")
        }
        return written
    }

    /// One method because ``RemoteFileOperation`` is the unit both ends share, so the browser composes it once. Answers with a sentence because the caller re-lists the folder either way. Throws as ``browse`` does.
    @discardableResult
    public func change(_ operation: RemoteFileOperation) async throws -> String {
        // The path the operation is about, which the answer is keyed to, matching the Mac's `changeFile`.
        let path: String
        switch operation {
        case .create(let target, _), .rename(let target, _), .delete(let target):
            path = target
        }

        guard case .changed(let note) = try await browse(.change(operation), at: path) else {
            throw SSHSessionError.browse("The server answered a change with something else.")
        }
        return note
    }

    /// Two guards cover two windows. ``ShellHandle/isAttached`` catches a session still connecting or failed. The yield's own result catches the loop ending just before the shell detaches: a `yield` into a finished stream drops its `CheckedContinuation`, and one deallocated unresumed is a trap rather than a hang.
    // MARK: - Forwarding

    /// The client half of a local port forward: Citadel's `createDirectTCPIPChannel` does the rest, this asks for one from outside the task that owns the client. Answers with a wrapped channel so the wrapping happens on the right event loop before anything reads (see ``NIOAsyncChannel``, which drops reads otherwise). `localPort` is the originator the server logs. Throws ``SSHSessionError/notConnected`` or ``SSHSessionError/forward(_:)``.
    public func openDirectChannel(
        to host: String,
        port: Int,
        from localPort: Int
    ) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        guard isUp.value else { throw SSHSessionError.notConnected }

        return try await withCheckedThrowingContinuation { continuation in
            let request = SSHForwardRequest(
                host: host,
                port: port,
                localPort: localPort,
                continuation: continuation
            )
            if case .terminated = issue.yield(.forward(request)) {
                continuation.resume(throwing: SSHSessionError.notConnected)
            }
        }
    }

    func browse(_ kind: SSHBrowseRequest.Kind, at path: String) async throws -> SSHBrowseResult {
        guard shell.isAttached else { throw SSHSessionError.notConnected }

        return try await withCheckedThrowingContinuation { continuation in
            let reply = SSHBrowseReply(continuation)
            let request = SSHBrowseRequest(kind: kind, path: path, reply: reply)
            if case .terminated = issue.yield(.browse(request)) {
                reply.resume(throwing: SSHSessionError.notConnected)
            }
        }
    }
}
