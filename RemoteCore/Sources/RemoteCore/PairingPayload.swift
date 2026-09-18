import Foundation

/// What is wrong with text that was supposed to be a Mac's device ID.
///
/// Every case is a different thing to say, rather than one "that did not work". The three
/// ways this fails are three different mistakes with three different remedies: a code
/// scanned off the wrong screen, a code that is not ours at all, and an ID that was
/// mistyped. A single sentence covering all three would send the user to check all three.
public enum PairingPayloadError: LocalizedError, Sendable, Equatable {
    /// Nothing was entered, or only whitespace.
    case empty
    /// A six-digit pairing code arrived where a device ID was wanted. Either it was scanned
    /// from the Mac's pairing panel or typed in from the digits on it.
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
/// Both live in one file because they are one decision. The two codes are read by two
/// different screens in the iPhone app, and each has to refuse the other's: a six-digit
/// pairing code entered into the "connect from another network" screen would otherwise be
/// sent to the relay as a device ID and fail there with something about registration.
/// Keeping both encodings and both parsers together is what makes that refusal a property
/// of the format rather than a coincidence of two parsers written months apart.
///
/// **The two codes are different kinds of thing, and the difference is the point.**
/// `peering://pair?code=NNNNNN` carries the short authentication string: a value both
/// screens derive from the pairing transcript and the two people compare. It is what
/// authorises the pairing. `peering://mac?id=<uuid>` carries the Mac's device ID, which is
/// an *address* — the name the relay knows this Mac by. It is not a secret and holds no
/// authority: pasting one licenses this app to dial a Mac it has never met, and proves
/// nothing at all about the Mac that answers. Whoever is at the Mac still has to compare
/// six digits with whoever is holding the phone, and that comparison is the authentication.
/// Treating the ID as a credential would be a real regression, so nothing here does.
public enum PairingPayload {
    public static let scheme = "peering"

    /// The host component of the short-authentication-string code, unchanged from what the
    /// host has always drawn on its pairing panel.
    public static let codeHost = "pair"

    /// The host component of the device-identifier code.
    ///
    /// A different word from ``codeHost`` on purpose, and the difference is load-bearing:
    /// both scanners test the host first, so a code shown on the pairing panel can never be
    /// read as a Mac to dial, and a Mac's ID can never be entered as a pairing code.
    public static let identifierHost = "mac"

    public static let codeKey = "code"
    public static let identifierKey = "id"

    /// The one spelling of a device ID that everything compares in.
    ///
    /// Uppercase and hyphenated, which is what ``UUID/uuidString`` produces and therefore
    /// what a ``DeviceIdentity`` mints and what the relay has registered the Mac under. The
    /// user may type the ID in any case, and the relay matches the string exactly, so the
    /// route from "what was typed" to "what is dialled" passes through here.
    ///
    /// - Returns: the canonical spelling, or `nil` if this is not a UUID at all.
    public static func canonicalIdentifier(_ text: String) -> String? {
        UUID(uuidString: text)?.uuidString
    }

    /// The QR payload for a Mac's device ID.
    public static func encode(hostID: String) -> String {
        // Falls back to whatever it was given rather than refusing: this is the Mac's own ID
        // from its own store, so a value that is not a UUID is a bug worth seeing on screen
        // rather than a QR code that silently does not draw.
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

    /// Reads a device ID out of what was typed, pasted or scanned.
    ///
    /// A bare ID is accepted as well as the URL, because the two ways this value arrives are
    /// a copy of the ID from the Mac's window and a scan of its QR code, and the first of
    /// those has no URL in it.
    public static func hostID(from raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PairingPayloadError.empty }

        // Before anything is parsed as a URL: a bare UUID is also a legal relative URL.
        if let canonical = canonicalIdentifier(text) { return canonical }

        // Digits typed in from the Mac's pairing panel. Not a URL at all, so this has to be
        // asked before the parsing below rather than by it.
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
            // The Mac's pairing panel, scanned into the wrong screen. Worth its own sentence
            // rather than "not an ID", because the user did scan a Peering code and will
            // otherwise scan it again.
            throw PairingPayloadError.shortAuthenticationCode
        case identifierHost:
            let value = components.queryItems?.first { $0.name == identifierKey }?.value ?? ""
            guard let canonical = canonicalIdentifier(value) else {
                throw PairingPayloadError.notAnIdentifier(value)
            }
            return canonical
        default:
            // Includes `peering://connect`, the Live Activity's own URL, and every QR code
            // that has nothing to do with this app.
            throw PairingPayloadError.unrecognisedCode
        }
    }

    /// Reads a six-digit code out of a scanned payload, or `nil` if it is not one.
    ///
    /// Optional rather than throwing, and the opposite of ``hostID(from:)``, because the
    /// caller is the pairing prompt: it already has the digits it expects and is only asking
    /// whether this scan is them. A wrong scan there is a mismatch to report, not a mistake
    /// to explain.
    public static func code(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Typed or pasted digits, for the same reason a bare ID is accepted above.
        if isShortAuthenticationCode(text) { return text }

        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == codeHost,
              let value = components.queryItems?.first(where: { $0.name == codeKey })?.value,
              isShortAuthenticationCode(value)
        else { return nil }
        return value
    }

    /// Whether this is exactly six digits, which is the whole shape of a pairing code.
    ///
    /// Six digits is also what a mistyped device ID is likely to be, and that is the point:
    /// the two are told apart by shape before anything tries to interpret them.
    public static func isShortAuthenticationCode(_ text: String) -> Bool {
        text.count == PairingSAS.digitCount && text.allSatisfy(\.isNumber)
    }
}
