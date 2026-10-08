import Foundation

/// What the Mac will fetch for the phone's web preview, decided without a network so it can be tested.
///
/// The proxy is not a general one. It dials `127.0.0.1` and nothing else, on a port the request names, so it cannot reach the LAN or the internet, and it refuses the port this app itself listens on.
public enum PreviewProxyPolicy {
    public static let allowedMethods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
    public static let blockedPorts: Set<UInt16> = [ProtocolInfo.defaultPort]
    /// The only addresses a preview URL may name.
    public static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1"]

    public static func isLoopbackHost(_ host: String) -> Bool {
        loopbackHosts.contains(host.lowercased())
    }

    public static func isAllowed(port: UInt16) -> Bool {
        port != 0 && !blockedPorts.contains(port)
    }

    /// `nil` when the request may be served.
    public static func refusal(for request: PreviewProxyRequest) -> PreviewFailure? {
        guard isAllowed(port: request.port), allowedMethods.contains(request.method) else { return .notAllowed }
        guard isValid(target: request.target), request.headers.count <= PreviewProxyLimits.maxHeaderCount else {
            return .invalidRequest
        }
        if let body = request.body, body.count > PreviewProxyLimits.maxRequestBodyBytes { return .tooLarge }
        return nil
    }

    /// A single leading `/` and nothing that could turn the string into another authority or split a header.
    public static func isValid(target: String) -> Bool {
        guard target.hasPrefix("/"), !target.hasPrefix("//"), target.utf8.count <= PreviewProxyLimits.maxTargetLength else {
            return false
        }
        return target.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value != 0x7F && $0 != "\\" }
    }

    /// Always `http://127.0.0.1:<port><target>`. Checked after parsing, because a hostile target is exactly what the parse would reinterpret.
    public static func destination(port: UInt16, target: String) -> URL? {
        guard isAllowed(port: port), isValid(target: target),
              let url = URL(string: "http://127.0.0.1:\(port)\(target)"),
              url.host == "127.0.0.1", url.port == Int(port), url.user == nil
        else { return nil }
        return url
    }

    // MARK: Headers

    private static let requestHeaders: Set<String> = [
        "accept", "accept-language", "content-type", "user-agent", "if-none-match", "if-modified-since",
        "range", "authorization", "cookie", "origin", "referer",
    ]

    private static let responseHeaders: Set<String> = [
        "content-type", "cache-control", "etag", "last-modified", "expires", "content-language",
        "content-disposition", "location", "accept-ranges", "content-range", "vary",
        "access-control-allow-origin", "access-control-allow-credentials", "access-control-allow-methods",
        "access-control-allow-headers", "access-control-expose-headers", "access-control-max-age",
    ]

    /// Only what a page needs. Host, framing and connection headers are the proxy's own, and `Origin` and `Referer` are put back to the `http://localhost:<port>` the server expects.
    public static func filteredRequestHeaders(_ headers: [PreviewHeader]) -> [PreviewHeader] {
        headers.compactMap { header in
            let name = header.name.lowercased()
            guard requestHeaders.contains(name) || name.hasPrefix("x-"), isSafe(header) else { return nil }
            return PreviewHeader(name: header.name, value: PreviewURLMapping.restoringHTTPURLs(in: header.value))
        }
    }

    /// `Set-Cookie`, security policies and framing headers are dropped: the page lives under another scheme, where a policy written for `http://localhost` would only break it.
    public static func filteredResponseHeaders(_ headers: [PreviewHeader]) -> [PreviewHeader] {
        headers.filter { responseHeaders.contains($0.name.lowercased()) && isSafe($0) }
    }

    /// By scalar: Swift reads CRLF as one `Character` that is neither `\r` nor `\n`.
    private static func isSafe(_ header: PreviewHeader) -> Bool {
        let forbidden: (Unicode.Scalar) -> Bool = { $0 == "\r" || $0 == "\n" || $0 == "\0" }
        return !header.name.isEmpty && !header.name.contains(":") && !header.name.unicodeScalars.contains(where: forbidden)
            && !header.value.unicodeScalars.contains(where: forbidden)
    }
}
