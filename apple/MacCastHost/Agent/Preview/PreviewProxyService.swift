import Foundation
import RemoteCore

/// Serves the phone's web preview: fetches from this Mac's own loopback on the phone's behalf, and from nowhere else.
final class PreviewProxyService: @unchecked Sendable {
    typealias Sink = @Sendable (PreviewProxyEvent) -> Void

    private let lock = NSLock()
    // Guarded by `lock`: open transfers, keyed `clientID#requestID`.
    private var transfers: [String: PreviewTransfer] = [:]

    func handle(clientID: String, command: PreviewProxyCommand, sink: @escaping Sink) {
        switch command {
        case .fetch(let request):
            fetch(clientID: clientID, request: request, sink: sink)
        case .cancel(let id):
            let transfer = lock.withLock { transfers.removeValue(forKey: Self.key(clientID, id)) }
            transfer?.cancel()
        }
    }

    func disconnect(clientID: String) {
        let prefix = "\(clientID)#"
        let dropped = lock.withLock {
            let keys = transfers.keys.filter { $0.hasPrefix(prefix) }
            return keys.compactMap { transfers.removeValue(forKey: $0) }
        }
        dropped.forEach { $0.cancel() }
    }

    private func fetch(clientID: String, request: PreviewProxyRequest, sink: @escaping Sink) {
        if let refusal = PreviewProxyPolicy.refusal(for: request) {
            return sink(.failure(id: request.id, reason: refusal))
        }
        guard let url = PreviewProxyPolicy.destination(port: request.port, target: request.target) else {
            return sink(.failure(id: request.id, reason: .invalidRequest))
        }
        let key = Self.key(clientID, request.id)
        let transfer = PreviewTransfer(id: request.id, sink: sink) { [weak self] in
            self?.lock.withLock { _ = self?.transfers.removeValue(forKey: key) }
        }
        let accepted = lock.withLock { () -> Bool in
            let open = transfers.keys.filter { $0.hasPrefix("\(clientID)#") }.count
            guard open < PreviewProxyLimits.maxInFlightPerClient, transfers[key] == nil else { return false }
            transfers[key] = transfer
            return true
        }
        guard accepted else { return sink(.failure(id: request.id, reason: .busy)) }
        transfer.start(Self.urlRequest(for: request, url: url))
    }

    private static func urlRequest(for request: PreviewProxyRequest, url: URL) -> URLRequest {
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = false
        for header in PreviewProxyPolicy.filteredRequestHeaders(request.headers) {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.name)
        }
        return urlRequest
    }

    private static func key(_ clientID: String, _ id: UInt32) -> String { "\(clientID)#\(id)" }
}
