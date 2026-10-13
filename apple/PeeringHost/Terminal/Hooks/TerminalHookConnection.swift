import Foundation
import PeeringKit

/// One hook process: reads its line, hands it on, and writes the answer back when there is one.
final class TerminalHookConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let queue: DispatchQueue
    private let deadline: DispatchTimeInterval
    private let limit: Int
    private let handler: TerminalHookServer.Handler

    // Everything below is touched only on `queue`.
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var handedOn = false
    private var finished = false

    init(descriptor: Int32, queue: DispatchQueue, deadline: DispatchTimeInterval, limit: Int, handler: @escaping TerminalHookServer.Handler) {
        self.descriptor = descriptor
        self.queue = queue
        self.deadline = deadline
        self.limit = limit
        self.handler = handler
    }

    /// Called on `queue`.
    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [self] in readAvailable() }
        self.source = source
        source.resume()
        queue.asyncAfter(deadline: .now() + deadline) { [self] in
            guard !handedOn else { return }
            handedOn = true
            finish(with: nil)
        }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let count = read(descriptor, &chunk, chunk.count)
        if count > 0 { buffer.append(contentsOf: chunk.prefix(count)) }
        // The relay ends the line itself, and a closed pipe ends it too.
        guard buffer.contains(UInt8(ascii: "\n")) || count <= 0 || buffer.count > limit, !handedOn else { return }
        handedOn = true
        // A half-closed pipe stays readable, so a source left running here would spin until the answer comes.
        source?.cancel()
        source = nil

        guard buffer.count <= limit, let event = ClaudeHookEvent.parse(buffer) else {
            finish(with: nil)
            return
        }
        handler(event) { [self] reply in queue.async { self.finish(with: reply) } }
    }

    private func finish(with reply: Data?) {
        guard !finished else { return }
        finished = true
        source?.cancel()
        source = nil
        if let reply { Self.writeAll(reply, to: descriptor) }
        close(descriptor)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, base + offset, bytes.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }
}
