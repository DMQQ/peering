import Foundation
import Testing

@testable import MacCastKit

@Suite("Trimming under memory pressure")
struct MemoryTrimTests {
    @Test func aTerminalKeepsTheNewestBytes() {
        var terminal = RemoteTerminal(id: UUID(), name: "sh", isRunning: true)
        terminal.output = Data("abcdefghij".utf8)
        terminal.trimOutput(keeping: 4)
        #expect(String(decoding: terminal.output, as: UTF8.self) == "ghij")
    }

    @Test func aShortTerminalIsUntouched() {
        var terminal = RemoteTerminal(id: UUID(), name: "sh", isRunning: true)
        terminal.output = Data("abc".utf8)
        terminal.trimOutput(keeping: 4)
        #expect(String(decoding: terminal.output, as: UTF8.self) == "abc")
    }

    @Test func aSmallTranscriptSurvivesATrim() {
        var transcript = AgentTranscript()
        transcript.markPromptSent()
        transcript.trimForMemoryPressure()
        #expect(transcript.state == .working)
    }
}
