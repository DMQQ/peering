import Citadel
import Crypto
import Foundation
import NIO
import NIOFoundationCompat
import NIOSSH
import RemoteCore
import os

/// Boxed to move into tasks. `TTYOutput` and `TTYStdinWriter` are thin handles over one NIO `Channel`, safe from any thread, but Citadel does not declare them `Sendable` (public conformance is not inferred across modules), so it is asserted here once.
struct BoxedShell: @unchecked Sendable {
    let inbound: TTYOutput
    let outbound: TTYStdinWriter
}

/// A lock rather than actor state: `TTYStdinWriter` is not `Sendable`, so storing it in an actor is itself a "sending" error.
final class ShellHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var boxed: BoxedShell?
    private var columns: Int
    private var rows: Int

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    /// Every access goes through one of these four synchronous helpers: `NSLock` may not be held across a suspension point, and an `await` inside the critical section would let another command in between the read and the write.
    private func swap(_ shell: BoxedShell?) -> BoxedShell? {
        lock.lock()
        defer { lock.unlock() }
        let previous = boxed
        boxed = shell
        return previous
    }

    private var current: BoxedShell? {
        lock.lock()
        defer { lock.unlock() }
        return boxed
    }

    private func record(columns: Int, rows: Int) -> (Int, Int) {
        lock.lock()
        defer { lock.unlock() }
        self.columns = columns
        self.rows = rows
        return (columns, rows)
    }

    private func size() -> (Int, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (columns, rows)
    }

    func attach(_ shell: BoxedShell) async {
        _ = swap(shell)
        // A resize made while the connection was still opening is applied once there is a shell.
        let (cols, rowCount) = size()
        try? await shell.outbound.changeSize(cols: cols, rows: rowCount, pixelWidth: 0, pixelHeight: 0)
    }

    func detach() {
        _ = swap(nil)
    }

    /// Read by browse requests: a request yielded with no loop running would hold a continuation nothing resumes. It covers a session still connecting and one whose connection failed; the rest is caught by the yield itself (see ``SSHSession/browse(_:at:)``).
    var isAttached: Bool {
        current != nil
    }

    func send(_ data: Data) async throws {
        guard let shell = current else { throw SSHSessionError.notConnected }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await shell.outbound.write(buffer)
    }

    func resize(columns: Int, rows: Int) async throws {
        let (cols, rowCount) = record(columns: columns, rows: rows)
        guard let shell = current else { return }
        try await shell.outbound.changeSize(cols: cols, rows: rowCount, pixelWidth: 0, pixelHeight: 0)
    }
}
