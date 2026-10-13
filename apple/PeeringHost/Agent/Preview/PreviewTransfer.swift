import Foundation
import RemoteCore

/// One request to a loopback server, streamed back as events. It owns its own session so that cancelling it cancels exactly one thing.
final class PreviewTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let id: UInt32
    private let sink: @Sendable (PreviewProxyEvent) -> Void
    private let onFinished: @Sendable () -> Void
    private let delegateQueue: OperationQueue
    // Everything below is touched only on `delegateQueue`, which is serial.
    private var pending = Data()
    private var received = 0
    private var sentHead = false
    private var truncated = false
    private var session: URLSession?

    init(
        id: UInt32,
        sink: @escaping @Sendable (PreviewProxyEvent) -> Void,
        onFinished: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.sink = sink
        self.onFinished = onFinished
        delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
    }

    func start(_ request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        // An empty dictionary, not nil: the system proxy must never see a loopback request.
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        delegateQueue.addOperation { self.session = session }
        session.dataTask(with: request).resume()
        session.finishTasksAndInvalidate()
    }

    func cancel() {
        // Silent: the phone asked for this and is no longer listening.
        delegateQueue.addOperation { [self] in
            session?.invalidateAndCancel()
            onFinished()
        }
    }

    // MARK: URLSessionDataDelegate

    /// A redirect is the page's to follow, through the scheme: followed here, one could leave loopback.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            sink(.failure(id: id, reason: .failed))
            completionHandler(.cancel)
            return
        }
        let headers = http.allHeaderFields.compactMap { key, value -> PreviewHeader? in
            guard let name = key as? String, let value = value as? String else { return nil }
            return PreviewHeader(name: name, value: value)
        }
        sentHead = true
        sink(.head(id: id, status: http.statusCode, headers: PreviewProxyPolicy.filteredResponseHeaders(headers)))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let room = PreviewProxyLimits.maxResponseBytes - received
        let kept = data.prefix(max(room, 0))
        received += kept.count
        pending.append(kept)
        flush(all: false)
        if kept.count < data.count {
            truncated = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { onFinished() }
        if let error {
            let code = (error as? URLError)?.code
            if truncated, code == .cancelled {
                flush(all: true)
                sink(.end(id: id, truncated: true))
            } else if code != .cancelled {
                sink(.failure(id: id, reason: Self.failure(for: code, sentHead: sentHead)))
            }
            return
        }
        flush(all: true)
        sink(.end(id: id, truncated: false))
    }

    private func flush(all: Bool) {
        let size = PreviewProxyLimits.chunkBytes
        while pending.count >= size || (all && !pending.isEmpty) {
            let chunk = pending.prefix(size)
            pending.removeFirst(chunk.count)
            sink(.body(id: id, data: Data(chunk)))
        }
    }

    private static func failure(for code: URLError.Code?, sentHead: Bool) -> PreviewFailure {
        switch code {
        case .cannotConnectToHost where !sentHead: .notListening
        case .timedOut: .timedOut
        default: .failed
        }
    }
}
