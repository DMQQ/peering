import RemoteCore

/// Finds which of the usual dev-server ports have something listening on the Mac, by asking the proxy for `HEAD /` on each.
enum PreviewPortProbe {
    static let commonPorts: [UInt16] = [3000, 3001, 4173, 5173, 8000, 8080]

    @MainActor
    static func listening(using fetch: PreviewSchemeHandler.Fetch) async -> [UInt16] {
        let streams = commonPorts.map { port in (port, fetch(port, "HEAD", "/", [], nil)) }
        var found: [UInt16] = []
        for (port, stream) in streams {
            for await event in stream {
                if case .head = event { found.append(port) }
                break
            }
        }
        return found
    }
}
