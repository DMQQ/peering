import Testing

@testable import RemoteCore

@Suite("The pairing code is six ASCII digits")
struct PairingCodeDigitsTests {
    @Test func acceptsSixAsciiDigits() {
        #expect(PairingPayload.isShortAuthenticationCode("012345"))
    }

    @Test func rejectsDigitsFromOtherScripts() {
        #expect(!PairingPayload.isShortAuthenticationCode("١٢٣٤٥٦"))
        #expect(!PairingPayload.isShortAuthenticationCode("１２３４５６"))
    }

    @Test func rejectsTheWrongLengthOrLetters() {
        #expect(!PairingPayload.isShortAuthenticationCode("12345"))
        #expect(!PairingPayload.isShortAuthenticationCode("12345a"))
    }
}
