import Foundation

/// How a loopback address is carried inside the phone's web view: `http://localhost:3000/a?b` is shown as `peering-preview://localhost:3000/a?b`, so the view asks the proxy for it instead of the phone's own network.
public enum PreviewURLMapping {
    public static let scheme = "peering-preview"

    public static func previewURL(port: UInt16, target: String = "/") -> URL? {
        PreviewProxyPolicy.isAllowed(port: port) ? URL(string: "\(scheme)://localhost:\(port)\(target)") : nil
    }

    /// The port and target a preview URL names, or `nil` for anything that is not a loopback preview address.
    public static func parse(_ url: URL) -> (port: UInt16, target: String)? {
        guard url.scheme == scheme, let host = url.host, PreviewProxyPolicy.isLoopbackHost(host),
              let port = url.port.flatMap(UInt16.init(exactly:)), PreviewProxyPolicy.isAllowed(port: port),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let target = targetString(of: parts)
        return PreviewProxyPolicy.isValid(target: target) ? (port, target) : nil
    }

    /// What the user typed in the address field. `3000`, `localhost:3000/docs`, `127.0.0.1:5173` and a full `http://localhost:3000/` are taken; any other host is not, so the field cannot be used to ask for the LAN or the internet.
    public static func url(fromTyped text: String) -> URL? {
        var typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let port = UInt16(typed) { return previewURL(port: port) }
        for prefix in ["http://", "https://"] where typed.lowercased().hasPrefix(prefix) {
            typed = String(typed.dropFirst(prefix.count))
        }
        guard !typed.contains("@"), let parts = URLComponents(string: "\(scheme)://\(typed)"), let host = parts.host,
              PreviewProxyPolicy.isLoopbackHost(host), let port = parts.port.flatMap(UInt16.init(exactly:))
        else { return nil }
        return previewURL(port: port, target: targetString(of: parts))
    }

    /// An `http(s)://localhost:<port>/...` address as its preview twin, or `nil` for any other host or a URL with no port.
    public static func previewURL(forLoopback url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, PreviewProxyPolicy.isLoopbackHost(host),
              let port = url.port.flatMap(UInt16.init(exactly:)),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return previewURL(port: port, target: targetString(of: parts))
    }

    /// What the address field shows for a page: the loopback address it stands for.
    public static func displayAddress(for url: URL) -> String? {
        parse(url).map { "localhost:\($0.port)\($0.target)" }
    }

    private static func targetString(of parts: URLComponents) -> String {
        let path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        return parts.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
    }

    // MARK: Text

    private static let loopbackURL = try? NSRegularExpression(
        pattern: #"(?:https?:)?//(?:localhost|127\.0\.0\.1):(\d{1,5})(?![\d])"#, options: [.caseInsensitive]
    )
    private static let previewOrigin = try? NSRegularExpression(
        pattern: #"\#(scheme)://localhost:(\d{1,5})(?![\d])"#
    )

    /// Absolute loopback URLs in a page, stylesheet or script pointed at the preview scheme. Only URLs with an explicit port: the proxy has no port 80.
    public static func rewritingLoopbackURLs(in text: String) -> String {
        replace(loopbackURL, in: text, with: "\(scheme)://localhost:$1")
    }

    /// The inverse, for headers going to the server.
    public static func restoringHTTPURLs(in text: String) -> String {
        replace(previewOrigin, in: text, with: "http://localhost:$1")
    }

    private static func replace(_ expression: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let expression else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// Only these are read through and rewritten; a picture or a font passes untouched.
    public static func isRewritable(contentType: String?) -> Bool {
        guard let type = contentType?.lowercased() else { return false }
        return ["text/html", "text/css", "javascript", "application/json", "image/svg+xml", "text/plain"]
            .contains { type.contains($0) }
    }

    // MARK: Redirects

    public enum Redirect: Equatable, Sendable {
        /// Not a redirect, or one with nowhere to go.
        case notARedirect
        case follow(URL)
        /// Leaves the loopback preview, which the page may not do.
        case refuse
    }

    /// A 3xx's `Location`, resolved against the URL that was asked for. A target on loopback is brought into the scheme; anything else is refused, never followed.
    public static func redirect(status: Int, location: String?, from requested: URL) -> Redirect {
        guard [301, 302, 303, 307, 308].contains(status), let location, !location.isEmpty else { return .notARedirect }
        guard let resolved = URL(string: location, relativeTo: requested)?.absoluteURL,
              let scheme = resolved.scheme?.lowercased()
        else { return .refuse }
        if scheme == Self.scheme { return parse(resolved) == nil ? .refuse : .follow(resolved) }
        return previewURL(forLoopback: resolved).map(Redirect.follow) ?? .refuse
    }
}
