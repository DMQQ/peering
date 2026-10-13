import Foundation
import RemoteCore
import Testing
@testable import PeeringKit

@Suite struct ControlTextPolicyTests {
    private let session = UUID()

    private func wireSizes(of text: String) -> [Int] {
        [
            (try? MessageCodec.encode(RemoteCommand.pushClipboard(text: text)).count) ?? Int.max,
            (try? MessageCodec.encode(AgentRequest.prompt(sessionID: session, text: text)).count) ?? Int.max,
        ]
    }

    @Test func plainTextWellUnderTheLimitFits() {
        let text = String(repeating: "a", count: 40 * 1024)
        #expect(ControlTextPolicy.verdict(forClipboardOrPrompt: text) == .fits)
    }

    @Test func plainTextOverTheLimitIsRefusedWithItsSize() {
        let text = String(repeating: "a", count: ProtocolInfo.maxControlPayload)
        guard case .tooLong(let bytes, let limit) = ControlTextPolicy.verdict(forClipboardOrPrompt: text) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(bytes >= ProtocolInfo.maxControlPayload)
        #expect(limit == ControlTextPolicy.maximumEncodedBytes)
    }

    @Test func textThatEscapesPastTheLimitIsRefusedEvenThoughItsBytesAreFewer() {
        for unit in ["\"", "\\", "/", "\u{01}", "\n"] {
            let text = String(repeating: unit, count: 40 * 1024)
            #expect(text.utf8.count < ControlTextPolicy.maximumEncodedBytes)
            #expect(ControlTextPolicy.verdict(forClipboardOrPrompt: text) != .fits, "\(unit.debugDescription)")
        }
    }

    @Test func textTheVerdictAcceptsReallyFitsOnTheWire() {
        for unit in ["\"", "\\", "/", "\u{01}", "é", "🙂", "a"] {
            for count in stride(from: 1000, through: 40 * 1024, by: 3000) {
                let text = String(repeating: unit, count: count)
                guard ControlTextPolicy.verdict(forClipboardOrPrompt: text) == .fits else { continue }
                for size in wireSizes(of: text) { #expect(size <= ProtocolInfo.maxControlPayload - ControlTextPolicy.margin) }
            }
        }
    }

    @Test func theLimitLeavesRoomUnderTheHostCap() {
        #expect(ControlTextPolicy.maximumEncodedBytes < ProtocolInfo.maxControlPayload)
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

    @Test func everyChunkOfBytesThatBase64EscapesAsSlashesFitsOnTheWire() {
        let data = Data(repeating: 0xFF, count: 200 * 1024)
        let chunks = ControlTextPolicy.terminalChunks(data)
        #expect(chunks.reduce(Data(), +) == data)
        for chunk in chunks {
            let size = (try? MessageCodec.encode(TerminalRequest.input(sessionID: session, data: chunk)).count) ?? Int.max
            #expect(size <= ProtocolInfo.maxControlPayload - ControlTextPolicy.margin)
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

    @Test func aCommitWithAFewFilesAndAShortMessageFits() {
        #expect(ControlTextPolicy.verdict(forCommitOf: ["a.swift", "b/c.swift"], message: "Fix the thing") == .fits)
    }

    @Test func aCommitWhosePathsAloneOutgrowTheLimitIsRefused() {
        let paths = (0..<3_000).map { "Sources/Module/Feature/File\($0)/Implementation.swift" }
        guard case .tooLong(let bytes, let limit) = ControlTextPolicy.verdict(forCommitOf: paths, message: "ok") else {
            Issue.record("expected a refusal")
            return
        }
        #expect(bytes > limit)
    }

    @Test func aCommitMessageThatEscapesPastTheLimitIsRefused() {
        let message = String(repeating: "\"", count: 40 * 1024)
        #expect(ControlTextPolicy.verdict(forCommitOf: ["a"], message: message) != .fits)
    }
}
