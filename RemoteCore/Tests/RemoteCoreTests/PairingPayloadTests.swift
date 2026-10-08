import Foundation
import Testing

@testable import RemoteCore

@Suite("Pairing payloads")
struct PairingPayloadTests {
    private let macID = "3D9F1C7A-2B44-4E71-9C0A-5F2E8B1D6A33"

    // MARK: - The device identifier

    @Test("a device ID survives the round trip through the QR payload")
    func roundTrip() throws {
        let payload = PairingPayload.encode(hostID: macID)
        #expect(payload == "https://getpeering.app/mac?id=\(macID)")
        #expect(try PairingPayload.hostID(from: payload) == macID)
    }

    @Test("the older scheme form and the www host still read")
    func otherSpellings() throws {
        #expect(try PairingPayload.hostID(from: "peering://mac?id=\(macID)") == macID)
        #expect(try PairingPayload.hostID(from: "https://www.getpeering.app/mac?id=\(macID)") == macID)
        #expect(throws: PairingPayloadError.unrecognisedCode) {
            try PairingPayload.hostID(from: "https://getpeering.app/download?id=\(macID)")
        }
        #expect(throws: PairingPayloadError.unrecognisedCode) {
            try PairingPayload.hostID(from: "https://example.com/mac?id=\(macID)")
        }
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

    @Test("six bare digits are refused as an ID")
    func refusesBareDigits() {
        #expect(throws: PairingPayloadError.shortAuthenticationCode) {
            try PairingPayload.hostID(from: "123456")
        }
    }

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

    @Test("each payload is refused by the other's parser")
    func mutualRefusal() {
        let identifier = PairingPayload.encode(hostID: macID)
        let code = PairingPayload.encode(code: "042317")

        #expect(PairingPayload.code(from: identifier) == nil)
        #expect(throws: PairingPayloadError.shortAuthenticationCode) {
            try PairingPayload.hostID(from: code)
        }
        #expect(identifier.hasPrefix("https://getpeering.app/mac?"))
        #expect(code.hasPrefix("peering://pair?"))
    }

    @Test("the code payload is spelled exactly as the host has always drawn it")
    func codePayloadIsUnchanged() {
        // Written out, not derived from `encode`: shipped builds scan this string, so a change breaks pairing between versions.
        #expect(PairingPayload.encode(code: "042317") == "peering://pair?code=042317")
    }
}
