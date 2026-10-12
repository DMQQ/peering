import Foundation
import RemoteCore
import Testing
@testable import MacCastKit

@Suite struct ControlTextPolicyTests {
    @Test func textAtTheCapFits() {
        let text = String(repeating: "a", count: ControlTextPolicy.maximumBytes)
        #expect(ControlTextPolicy.verdict(forClipboardOrPrompt: text) == .fits)
    }

    @Test func textOneByteOverTheCapIsRefusedWithItsSize() {
        let text = String(repeating: "a", count: 49153)
        #expect(ControlTextPolicy.verdict(forClipboardOrPrompt: text) == .tooLong(bytes: 49153, limit: 49152))
    }

    @Test func theCapCountsBytesNotCharacters() {
        let text = String(repeating: "é", count: 24577)
        #expect(ControlTextPolicy.verdict(forClipboardOrPrompt: text) != .fits)
    }

    @Test func theCapStaysUnderTheHostLimitEvenAsBase64() {
        #expect(ControlTextPolicy.maximumBytes < ProtocolInfo.maxControlPayload)
        #expect(ControlTextPolicy.terminalChunkBytes * 4 / 3 + 1024 < ProtocolInfo.maxControlPayload)
    }

    @Test func chunksJoinBackToTheOriginalBytes() {
        let data = Data(String(repeating: "héllo 日本語 🙂 ", count: 5000).utf8)
        let chunks = ControlTextPolicy.terminalChunks(data)
        #expect(chunks.count > 1)
        #expect(chunks.reduce(Data(), +) == data)
    }

    @Test func noChunkSplitsACharacter() {
        let data = Data(String(repeating: "🙂", count: 20000).utf8)
        for chunk in ControlTextPolicy.terminalChunks(data) {
            #expect(String(data: chunk, encoding: .utf8) != nil)
            #expect(chunk.count <= ControlTextPolicy.terminalChunkBytes)
        }
    }

    @Test func emptyInputMakesNoChunks() {
        #expect(ControlTextPolicy.terminalChunks(Data()).isEmpty)
    }

    @Test func aTerminalPasteOverAMegabyteIsRefused() {
        let data = Data(count: 1024 * 1024 + 1)
        #expect(ControlTextPolicy.verdict(forTerminalInput: data) != .fits)
        #expect(ControlTextPolicy.verdict(forTerminalInput: Data(count: 10)) == .fits)
    }
}
