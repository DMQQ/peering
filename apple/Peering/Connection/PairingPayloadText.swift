import Foundation
import RemoteCore

/// What the pairing sheet says for each way a typed or scanned ID can be wrong. The error's own sentences are English, for the log.
enum PairingPayloadText {
    static func message(for error: PairingPayloadError) -> String {
        switch error {
        case .empty:
            return String(localized: "Enter the Mac's device ID, or scan its code.")
        case .shortAuthenticationCode:
            return String(localized: "Those six digits are the pairing code, not the Mac's ID. Scan the QR code beside the device ID in Peering on the Mac.")
        case .unrecognisedCode:
            return String(localized: "That QR code is not a Peering pairing code. In Peering on the Mac, the code to scan is beside the device ID.")
        case .notAnIdentifier(let text):
            return String(localized: "“\(text)” is not a Mac's device ID. An ID is the 36-character code, with hyphens, that Peering shows on the Mac.")
        }
    }
}
