import Foundation

/// What is wrong with text that was supposed to be a Mac's device ID, one case per mistake:
/// the three failures have three different remedies, rather than one "that did not work".
public enum PairingPayloadError: LocalizedError, Sendable, Equatable {
    /// Nothing was entered, or only whitespace.
    case empty
    /// A six-digit pairing code arrived where a device ID was wanted, scanned or typed from the panel.
    case shortAuthenticationCode
    /// A QR code that is not one of ours, or one of our URLs that is not a pairing code.
    case unrecognisedCode
    /// Text that is neither a code nor an identifier.
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

/// The two things a Mac can show as a QR code, and the parser for each.
///
/// `peering://pair?code=NNNNNN` carries the short authentication string, the value both screens
/// derive from the pairing transcript and the two people compare: it authorises the pairing.
/// `peering://mac?id=<uuid>` carries the Mac's device ID, an address rather than a secret, which
/// holds no authority and proves nothing about the Mac that answers.
///
/// Both parsers live together so that each refuses the other's code as a property of the format.
public enum PairingPayload {
    public static let scheme = "peering"

    /// The host component of the short-authentication-string code, unchanged from what the host
    /// draws on its pairing panel.
    public static let codeHost = "pair"

    /// The host component of the device-identifier code, a different word from ``codeHost`` on
    /// purpose: both scanners test the host first, so neither code can be read as the other.
    public static let identifierHost = "mac"

    public static let codeKey = "code"
    public static let identifierKey = "id"

    /// The one spelling of a device ID that everything compares in: uppercase and hyphenated, which
    /// is what ``UUID/uuidString`` produces. The relay matches exactly, so typing passes through here.
    ///
    /// - Returns: the canonical spelling, or `nil` if this is not a UUID at all.
    public static func canonicalIdentifier(_ text: String) -> String? {
        UUID(uuidString: text)?.uuidString
    }

    /// The QR payload for a Mac's device ID.
    public static func encode(hostID: String) -> String {
        // Falls back to whatever it was given rather than refusing: this is the Mac's own ID from
        // its own store, so a value that is not a UUID is a bug worth seeing rather than hiding.
        let value = canonicalIdentifier(hostID) ?? hostID
        var components = URLComponents()
        components.scheme = scheme
        components.host = identifierHost
        components.queryItems = [URLQueryItem(name: identifierKey, value: value)]
        return components.string ?? "\(scheme)://\(identifierHost)?\(identifierKey)=\(value)"
    }

    /// The QR payload for a short authentication string.
    public static func encode(code: String) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = codeHost
        components.queryItems = [URLQueryItem(name: codeKey, value: code)]
        return components.string ?? "\(scheme)://\(codeHost)?\(codeKey)=\(code)"
    }

    /// Reads a device ID out of what was typed, pasted or scanned. A bare ID is accepted as well
    /// as the URL, because one of the two ways this value arrives has no URL in it.
    public static func hostID(from raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PairingPayloadError.empty }

        // Before anything is parsed as a URL: a bare UUID is also a legal relative URL.
        if let canonical = canonicalIdentifier(text) { return canonical }

        // Digits typed in from the Mac's pairing panel. Not a URL at all, so this has to be asked
        // before the parsing below rather than by it.
        guard !isShortAuthenticationCode(text) else {
            throw PairingPayloadError.shortAuthenticationCode
        }

        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased()
        else {
            throw PairingPayloadError.notAnIdentifier(text)
        }
        guard scheme == Self.scheme else { throw PairingPayloadError.unrecognisedCode }

        switch components.host?.lowercased() ?? "" {
        case codeHost:
            // The Mac's pairing panel, scanned into the wrong screen: the user did scan a Peering
            // code, so this is said plainly rather than as "not an ID".
            throw PairingPayloadError.shortAuthenticationCode
        case identifierHost:
            let value = components.queryItems?.first { $0.name == identifierKey }?.value ?? ""
            guard let canonical = canonicalIdentifier(value) else {
                throw PairingPayloadError.notAnIdentifier(value)
            }
            return canonical
        default:
            // Includes `peering://connect`, the Live Activity's own URL, and any QR code that has
            // nothing to do with this app.
            throw PairingPayloadError.unrecognisedCode
        }
    }

    /// Reads a six-digit code out of a scanned payload, or `nil` if it is not one.
    ///
    /// Optional rather than throwing, unlike ``hostID(from:)``: the caller already has the digits
    /// it expects, so a wrong scan is a mismatch to report rather than a mistake to explain.
    public static func code(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Typed or pasted digits, as a bare ID is accepted above.
        if isShortAuthenticationCode(text) { return text }

        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == codeHost,
              let value = components.queryItems?.first(where: { $0.name == codeKey })?.value,
              isShortAuthenticationCode(value)
        else { return nil }
        return value
    }

    /// Whether this is exactly six digits, which is the whole shape of a pairing code. A mistyped
    /// device ID is likely six digits too, so the two are told apart by shape before interpretation.
    public static func isShortAuthenticationCode(_ text: String) -> Bool {
        text.count == PairingSAS.digitCount && text.allSatisfy(\.isNumber)
    }
}
