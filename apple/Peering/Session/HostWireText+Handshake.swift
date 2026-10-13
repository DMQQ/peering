import Foundation
import PeeringKit

extension HostWireText {
    /// The sentences `RemoteCore` raises while it sets up a session, none of which the Mac sends.
    static func handshake(_ text: String) -> String? {
        switch text {
        case "The Mac's hello could not be read.": String(localized: "The Mac's hello could not be read.")
        case "The Mac's pairing commitment could not be read.": String(localized: "The Mac's pairing commitment could not be read.")
        case "The Mac's pairing reveal could not be read.": String(localized: "The Mac's pairing reveal could not be read.")
        case "The Mac's pairing result could not be read.": String(localized: "The Mac's pairing result could not be read.")
        case "The Mac's pairing reveal did not match its commitment.":
            String(localized: "The Mac's pairing reveal did not match its commitment.")
        case "The Mac's certificate did not expose a public key, so it cannot be pinned.":
            String(localized: "The Mac's certificate did not expose a public key, so it cannot be pinned.")
        case "This device could not obtain secure random bytes.": String(localized: "This device could not obtain secure random bytes.")
        case "The pairing exchange lost its state.": String(localized: "The pairing exchange lost its state.")
        default: patternedHandshake(text)
        }
    }

    private static func patternedHandshake(_ text: String) -> String? {
        if let found = SentenceTemplate.arguments(
            in: text, template: "This Mac speaks protocol v%@ and this app speaks v%@. Update whichever is older."
        ) {
            return String(localized: "This Mac speaks protocol v\(found[0]) and this app speaks v\(found[1]). Update whichever is older.")
        }
        if let found = SentenceTemplate.arguments(in: text, template: "Expected %@ from the Mac, got %@.") {
            return String(localized: "Expected \(found[0]) from the Mac, got \(found[1]).")
        }
        if let found = SentenceTemplate.arguments(in: text, template: "This device's identity could not be loaded: %@") {
            return String(localized: "This device's identity could not be loaded: \(found[0])")
        }
        return nil
    }
}
