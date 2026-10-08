import Testing
@testable import MacCastKit

struct ClipboardHistoryPolicyTests {
    @Test func ordinaryTextIsRemembered() {
        #expect(ClipboardHistoryPolicy.remembers("hello"))
    }

    @Test func blankTextIsNot() {
        #expect(!ClipboardHistoryPolicy.remembers(" \n"))
    }

    @Test func textOverTheByteLimitIsNot() {
        #expect(ClipboardHistoryPolicy.remembers(String(repeating: "a", count: 100_000)))
        #expect(!ClipboardHistoryPolicy.remembers(String(repeating: "a", count: 100_001)))
    }
}
