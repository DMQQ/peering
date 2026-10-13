import Foundation

/// Runs `handle` for each element one at a time, in the order they were enqueued, so sends that must arrive in order are never started by separate tasks that can overtake each other.
public final class SerialAsyncQueue<Element: Sendable>: Sendable {
    private let continuation: AsyncStream<Element>.Continuation

    public init(_ handle: @escaping @Sendable (Element) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
        self.continuation = continuation
        Task.detached {
            for await element in stream { await handle(element) }
        }
    }

    deinit { continuation.finish() }

    public func enqueue(_ element: Element) {
        continuation.yield(element)
    }

    /// Elements already enqueued still run; later ones are dropped.
    public func finish() {
        continuation.finish()
    }
}
