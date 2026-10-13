import Foundation
import PeeringKit
import os

private let hookServerLog = Logger(subsystem: "pl.dmq.peering.host", category: "terminal-hooks")

/// Listens on a Unix socket only this user can reach, for the one JSON line each Claude Code hook sends and the answer it waits for.
final class TerminalHookServer: @unchecked Sendable {
    typealias Reply = ClaudeHookBroker.Reply
    typealias Handler = @Sendable (ClaudeHookEvent, @escaping Reply) -> Void

    /// A hook line is a tool call and its input: well under this, and anything larger is not one.
    private static let maximumLineBytes = 512 * 1024
    private static let readDeadline: DispatchTimeInterval = .seconds(5)

    static var socketURL: URL {
        TerminalHookInstaller.supportDirectory.appendingPathComponent("hook.sock")
    }

    private let handler: Handler
    private let queue = DispatchQueue(label: "pl.dmq.peering.host.terminal-hooks")
    /// Only touched on `queue`.
    private var acceptSource: DispatchSourceRead?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() throws {
        try queue.sync {
            guard acceptSource == nil else { return }
            let descriptor = try Self.listeningSocket(at: Self.socketURL)
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.accept(on: descriptor) }
            source.setCancelHandler {
                close(descriptor)
                unlink(Self.socketURL.path)
            }
            acceptSource = source
            source.resume()
        }
        hookServerLog.notice("listening for Claude Code hooks")
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
        }
    }

    // MARK: - Accepting

    private func accept(on listener: Int32) {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        TerminalHookConnection(descriptor: client, queue: queue, deadline: Self.readDeadline, limit: Self.maximumLineBytes, handler: handler).start()
    }

    private static func listeningSocket(at url: URL) throws -> Int32 {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        unlink(url.path)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard url.path.utf8.count < capacity else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: url.path.utf8)
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(url.path, 0o600) == 0, listen(descriptor, 8) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(descriptor)
            throw POSIXError(code)
        }
        return descriptor
    }
}
