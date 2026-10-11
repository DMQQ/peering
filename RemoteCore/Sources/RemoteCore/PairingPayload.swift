import Foundation

/// One case per mistake, since the three failures have different remedies.
public enum PairingPayloadError: LocalizedError, Sendable, Equatable {
    case empty
    /// A six-digit pairing code arrived where a device ID was wanted, scanned or typed from the panel.
    case shortAuthenticationCode
    case unrecognisedCode
    case notAnIdentifier(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter the Mac's device ID, or scan its code."
        case .shortAuthenticationCode:
            return "Those six digits are the pairing code, not the Mac's ID. Scan the QR code beside the device ID in Peering on the Mac."
        case .unrecognisedCode:
            return "That QR code is not a Peering pairing code. In Peering on the Mac, the code to scan is beside the device ID."
        case .notAnIdentifier(let text):
            return "“\(text)” is not a Mac's device ID. An ID is the 36-character code, with hyphens, that Peering shows on the Mac."
        }
    }
}

/// `peering://pair?code=NNNNNN` carries the SAS both screens derive and compare: it authorises the pairing. `https://getpeering.app/mac?id=<uuid>` (formerly `peering://mac?id=<uuid>`) carries the Mac's device ID, an address with no authority.
/// Each parser refuses the other's code as a property of the format.
public enum PairingPayload {
    public static let scheme = "peering"

    public static let codeHost = "pair"

    /// Different from ``codeHost`` on purpose: both scanners test the host first, so neither code reads as the other.
    public static let identifierHost = "mac"

    public static let codeKey = "code"

    /// Claimed by the iPhone app as a universal link; a scan without the app lands on the site.
    public static let linkDomain = "getpeering.app"
    public static let linkPath = "/mac"
    public static let identifierKey = "id"

    /// Uppercase and hyphenated (``UUID/uuidString``); the relay matches exactly.
    public static func canonicalIdentifier(_ text: String) -> String? {
        UUID(uuidString: text)?.uuidString
    }

    public static func encode(hostID: String) -> String {
        // Falls back to the input: a non-UUID from the Mac's own store is a bug worth seeing.
        let value = canonicalIdentifier(hostID) ?? hostID
        var components = URLComponents()
        components.scheme = "https"
        components.host = linkDomain
        components.path = linkPath
        components.queryItems = [URLQueryItem(name: identifierKey, value: value)]
        return components.string ?? "https://\(linkDomain)\(linkPath)?\(identifierKey)=\(value)"
    }

    public static func isHostLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return (host == linkDomain || host == "www." + linkDomain) && url.path == linkPath
    }

    public static let secretKey = "secret"

    public static func encode(code: String, secret: Data? = nil) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = codeHost
        components.queryItems = [URLQueryItem(name: codeKey, value: code)]
        if let secret {
            components.queryItems?.append(URLQueryItem(name: secretKey, value: secret.map { String(format: "%02x", $0) }.joined()))
        }
        return components.string ?? "\(scheme)://\(codeHost)?\(codeKey)=\(code)"
    }

    /// The pairing secret in a scanned code, or `nil` for a code without one.
    public static func secret(from raw: String) -> Data? {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == codeHost,
              let hex = components.queryItems?.first(where: { $0.name == secretKey })?.value,
              hex.count.isMultiple(of: 2), !hex.isEmpty
        else { return nil }
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// A bare ID is accepted as well as the URL, since one way this value arrives has no URL.
    public static func hostID(from raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PairingPayloadError.empty }

        // Before anything is parsed as a URL: a bare UUID is also a legal relative URL.
        if let canonical = canonicalIdentifier(text) { return canonical }

        // Not a URL, so asked before the parsing below.
        guard !isShortAuthenticationCode(text) else {
            throw PairingPayloadError.shortAuthenticationCode
        }

        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased()
        else {
            throw PairingPayloadError.notAnIdentifier(text)
        }
        if scheme == "https", let url = components.url, isHostLink(url) {
            return try identifier(in: components)
        }
        guard scheme == Self.scheme else { throw PairingPayloadError.unrecognisedCode }

        switch components.host?.lowercased() ?? "" {
        case codeHost:
            // The user did scan a Peering code, so say so plainly.
            throw PairingPayloadError.shortAuthenticationCode
        case identifierHost:
            return try identifier(in: components)
        default:
            // Includes `peering://connect`, the Live Activity's own URL, and any QR code that has
            // nothing to do with this app.
            throw PairingPayloadError.unrecognisedCode
        }
    }

    private static func identifier(in components: URLComponents) throws -> String {
        let value = components.queryItems?.first { $0.name == identifierKey }?.value ?? ""
        guard let canonical = canonicalIdentifier(value) else {
            throw PairingPayloadError.notAnIdentifier(value)
        }
        return canonical
    }

    /// Optional rather than throwing: a wrong scan is a mismatch to report, not a mistake to explain.
    public static func code(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if isShortAuthenticationCode(text) { return text }

        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == codeHost,
              let value = components.queryItems?.first(where: { $0.name == codeKey })?.value,
              isShortAuthenticationCode(value)
        else { return nil }
        return value
    }

    /// Exactly six digits. A mistyped device ID can be six digits too, so shape is checked first.
    public static func isShortAuthenticationCode(_ text: String) -> Bool {
        text.count == PairingSAS.digitCount && text.allSatisfy(\.isNumber)
    }
}
