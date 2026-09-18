import Foundation
import Testing

@testable import RemoteCore

@Suite("Pairing payloads")
struct PairingPayloadTests {
    /// The spelling a `DeviceIdentity` mints, which is what a Mac's window shows.
    private let macID = "3D9F1C7A-2B44-4E71-9C0A-5F2E8B1D6A33"

    // MARK: - The device identifier

    @Test("a device ID survives the round trip through the QR payload")
    func roundTrip() throws {
        let payload = PairingPayload.encode(hostID: macID)
        #expect(payload == "peering://mac?id=\(macID)")
        #expect(try PairingPayload.hostID(from: payload) == macID)
    }

    @Test("a bare ID is accepted, which is what a paste gives")
    func bareIdentifier() throws {
        #expect(try PairingPayload.hostID(from: macID) == macID)
        #expect(try PairingPayload.hostID(from: "  \(macID)\n") == macID)
    }

    @Test("a lower-case ID is canonicalised, because the relay matches the string")
    func canonicalised() throws {
        let lower = macID.lowercased()
        #expect(try PairingPayload.hostID(from: lower) == macID)
        #expect(try PairingPayload.hostID(from: PairingPayload.encode(hostID: lower)) == macID)
    }

    /// Foundation's UUID parser wants the hyphens, and so does the sentence this failure
    /// produces: it says the ID is 36 characters with hyphens, which is what the Mac shows
    /// and what a copy gives.
    @Test("an ID without its hyphens is refused rather than guessed at")
    func unhyphenated() {
        let compact = macID.replacingOccurrences(of: "-", with: "")
        #expect(throws: PairingPayloadError.notAnIdentifier(compact)) {
            try PairingPayload.hostID(from: compact)
        }
    }

    // MARK: - The short authentication string, which must never be read as an ID

    @Test("the pairing code's own QR payload is refused as an ID, by name")
    func refusesThePairingCodePayload() {
        #expect(throws: PairingPayloadError.shortAuthenticationCode) {
            try PairingPayload.hostID(from: PairingPayload.encode(code: "123456"))
        }
    }

    /// The digits are on the Mac's screen in 42-point type and a user will try them.
    @Test("six bare digits are refused as an ID")
    func refusesBareDigits() {
        #expect(throws: PairingPayloadError.shortAuthenticationCode) {
            try PairingPayload.hostID(from: "123456")
        }
    }

    /// Five or seven digits are not a code either, so they are ordinary bad input rather
    /// than something to send the user back to the Mac's pairing panel for.
    @Test("a number that is not six digits long is not reported as a pairing code")
    func digitsOfTheWrongLength() {
        #expect(throws: PairingPayloadError.notAnIdentifier("12345")) {
            try PairingPayload.hostID(from: "12345")
        }
        #expect(throws: PairingPayloadError.notAnIdentifier("1234567")) {
            try PairingPayload.hostID(from: "1234567")
        }
    }

    // MARK: - Everything else

    @Test("empty input is its own answer")
    func empty() {
        #expect(throws: PairingPayloadError.empty) { try PairingPayload.hostID(from: "") }
        #expect(throws: PairingPayloadError.empty) { try PairingPayload.hostID(from: "   ") }
    }

    @Test("a QR code that is not ours is refused")
    func foreignCode() {
        #expect(throws: PairingPayloadError.unrecognisedCode) {
            try PairingPayload.hostID(from: "https://example.com/?id=\(macID)")
        }
        #expect(throws: PairingPayloadError.unrecognisedCode) {
            try PairingPayload.hostID(from: "peering://connect")
        }
        #expect(throws: PairingPayloadError.unrecognisedCode) {
            try PairingPayload.hostID(from: "WIFI:S:Cafe;T:WPA;P:hunter2;;")
        }
    }

    @Test("our own URL carrying something that is not an ID says so about the value")
    func ourURLBadValue() {
        #expect(throws: PairingPayloadError.notAnIdentifier("hello")) {
            try PairingPayload.hostID(from: "peering://mac?id=hello")
        }
        // A query item that is missing altogether is the same mistake as an empty one.
        #expect(throws: PairingPayloadError.notAnIdentifier("")) {
            try PairingPayload.hostID(from: "peering://mac")
        }
    }

    @Test("text that is neither a code nor an identifier names what was typed")
    func plainText() {
        #expect(throws: PairingPayloadError.notAnIdentifier("my mac")) {
            try PairingPayload.hostID(from: "my mac")
        }
    }

    // MARK: - The pairing code parser, and the mutual refusal

    @Test("the pairing code is read from the Mac's QR payload")
    func readsTheCode() {
        #expect(PairingPayload.code(from: PairingPayload.encode(code: "042317")) == "042317")
        #expect(PairingPayload.code(from: " 042317 ") == "042317")
    }

    @Test("the pairing code parser refuses everything that is not a six-digit code")
    func codeRefusals() {
        #expect(PairingPayload.code(from: "04231") == nil)
        #expect(PairingPayload.code(from: "0423178") == nil)
        #expect(PairingPayload.code(from: "04231x") == nil)
        #expect(PairingPayload.code(from: "https://example.com/?code=042317") == nil)
    }

    /// The two payloads are refused by each other's parser, which is what makes it
    /// impossible to scan one into the other's screen and get a plausible reading.
    @Test("each payload is refused by the other's parser")
    func mutualRefusal() {
        let identifier = PairingPayload.encode(hostID: macID)
        let code = PairingPayload.encode(code: "042317")

        #expect(PairingPayload.code(from: identifier) == nil)
        #expect(throws: PairingPayloadError.shortAuthenticationCode) {
            try PairingPayload.hostID(from: code)
        }
        // And they are distinguishable without parsing at all, by the host component.
        #expect(identifier.hasPrefix("peering://mac?"))
        #expect(code.hasPrefix("peering://pair?"))
    }

    @Test("the code payload is spelled exactly as the host has always drawn it")
    func codePayloadIsUnchanged() {
        // Written out rather than compared with `encode`, because this string is what
        // shipped builds put on screen and scan; a change here is a pairing that stops
        // working between two versions.
        #expect(PairingPayload.encode(code: "042317") == "peering://pair?code=042317")
    }
}
