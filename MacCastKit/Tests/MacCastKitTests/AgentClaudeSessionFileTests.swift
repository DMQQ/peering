import Foundation
import RemoteCore
import Testing

@testable import MacCastKit

struct AgentClaudeSessionFileTests {
    private let meta = #"{"type":"user","isMeta":true,"cwd":"/Users/a/app","message":{"role":"user","content":"<local-command-caveat>x</local-command-caveat>"}}"#
    private let slash = #"{"type":"user","cwd":"/Users/a/app","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#
    private let ask = #"{"type":"user","cwd":"/Users/a/app","message":{"role":"user","content":"fix the login bug"}}"#
    private let answer = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking now."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#
    private let result = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a.txt"}]}}"#
    private let sideChain = #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"sub-agent brief"}}"#
    private let bookkeeping = #"{"type":"attachment","cwd":"/Users/a/app"}"#

    @Test func theFolderIsTheOneTheCLIRecorded() {
        let summary = AgentClaudeSessionFile.summary(head: [meta, ask].joined(separator: "\n"), tail: "")
        #expect(summary?.directory == "/Users/a/app")
    }

    @Test func theCLIsOwnTitleBeatsTheFirstPrompt() {
        let title = #"{"type":"ai-title","aiTitle":"Login bug"}"#
        let summary = AgentClaudeSessionFile.summary(head: [meta, ask].joined(separator: "\n"), tail: title)
        #expect(summary?.title == "Login bug")
    }

    @Test func withoutATitleTheFirstRealPromptNamesIt() {
        let summary = AgentClaudeSessionFile.summary(head: [meta, slash, ask].joined(separator: "\n"), tail: "")
        #expect(summary?.title == "fix the login bug")
    }

    @Test func aWindowCutMidLineIsSkippedNotMisread() {
        let cut = #"ssage":{"role":"user","content":"torn"}}"#
        let summary = AgentClaudeSessionFile.summary(head: [meta, ask].joined(separator: "\n"), tail: cut)
        #expect(summary?.title == "fix the login bug")
    }

    @Test func aFileWithNoFolderIsNotListed() {
        #expect(AgentClaudeSessionFile.summary(head: #"{"type":"user","message":{"role":"user","content":"hi"}}"#, tail: "") == nil)
    }

    @Test func aLongTitleIsCut() {
        let long = String(repeating: "word ", count: 40)
        let line = #"{"type":"user","cwd":"/a","message":{"role":"user","content":"\#(long)"}}"#
        let title = AgentClaudeSessionFile.summary(head: line, tail: "")?.title ?? ""
        #expect(title.count <= 81)
        #expect(title.hasSuffix("…"))
    }

    @Test func theConversationRebuildsAsPromptReplyAndToolCall() {
        let text = [meta, slash, ask, answer, result, sideChain, bookkeeping].joined(separator: "\n")
        let events = AgentClaudeSessionFile.events(from: text)
        #expect(events.count == 4)
        #expect(events[0] == .userPrompt(text: "fix the login bug"))
        #expect(events[1] == .textFinal(text: "Looking now."))
        if case .toolStarted(let call) = events[2] {
            #expect(call.id == "t1")
            #expect(call.detail == "ls")
        } else {
            Issue.record("expected a tool call")
        }
        #expect(events[3] == .toolFinished(callID: "t1", ok: true, output: "a.txt", truncated: false))
    }

    @Test func aToolCallWithNoResultEndsAsFailedAndTheTurnCloses() {
        let events = AgentClaudeSessionFile.events(from: [ask, answer].joined(separator: "\n"))
        var transcript = AgentTranscript()
        for payload in AgentClaudeSessionFile.settled(events) { transcript.apply(payload) }
        #expect(transcript.state == .idle)
        #expect(transcript.pendingApprovals.isEmpty)
        let running = transcript.items.contains { item in
            if case .tool(_, let tool) = item { return tool.state == .running }
            return false
        }
        #expect(!running)
    }

    @Test func usageIsReadFromTheLastCallAndEachMessageCountsOnce() {
        let first = #"{"type":"assistant","message":{"id":"m1","role":"assistant","content":[],"usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":0,"output_tokens":5}}}"#
        let sameMessage = #"{"type":"assistant","message":{"id":"m1","role":"assistant","content":[],"usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":0,"output_tokens":5}}}"#
        let second = #"{"type":"assistant","message":{"id":"m2","role":"assistant","content":[],"usage":{"input_tokens":20,"cache_read_input_tokens":200,"cache_creation_input_tokens":30,"output_tokens":7}}}"#
        let usage = AgentClaudeSessionFile.usage(from: [first, sameMessage, second].joined(separator: "\n"))
        #expect(usage?.contextUsedTokens == 257)
        #expect(usage?.inputTokens == 60)
        #expect(usage?.cachedTokens == 300)
        #expect(usage?.outputTokens == 12)
    }

    @Test func aFileWithNoCallsHasNoUsage() {
        #expect(AgentClaudeSessionFile.usage(from: ask) == nil)
    }
}
