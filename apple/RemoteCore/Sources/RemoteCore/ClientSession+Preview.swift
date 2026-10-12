import Foundation

extension ClientSession {
    /// Asks the Mac to fetch one URL from its own loopback. The stream yields a head, bodies and an end, or a failure, and then finishes; dropping it early tells the Mac to stop.
    public func fetchPreview(
        port: UInt16,
        method: String,
        target: String,
        headers: [PreviewHeader],
        body: Data?
    ) -> AsyncStream<PreviewProxyEvent> {
        AsyncStream(bufferingPolicy: .bufferingOldest(PreviewRequestTable.maximumBufferedEvents)) { continuation in
            guard isReady, let connection = connection() else {
                continuation.yield(.failure(id: 0, reason: .disconnected))
                continuation.finish()
                return
            }
            let id = previewRequests.register(continuation)
            continuation.onTermination = { [weak self] _ in
                guard let self, self.previewRequests.remove(id) else { return }
                self.connection()?.send(.previewRequest, PreviewProxyCommand.cancel(id: id))
            }
            let request = PreviewProxyRequest(
                id: id,
                port: port,
                method: method,
                target: target,
                headers: PreviewProxyPolicy.filteredRequestHeaders(headers),
                body: body
            )
            connection.send(.previewRequest, PreviewProxyCommand.fetch(request))
        }
    }

    func handlePreviewEvent(_ frame: Frame) {
        guard let event = try? MessageCodec.decode(PreviewProxyEvent.self, from: frame.payload) else {
            clientSessionLog.error("could not decode a preview event, so it is being dropped")
            return
        }
        previewRequests.deliver(event)
    }
}
