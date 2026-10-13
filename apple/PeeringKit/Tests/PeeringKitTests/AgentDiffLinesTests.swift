import Testing

@testable import MacCastKit

struct AgentDiffLinesTests {
    @Test func readsPathAndCountsBothSides() {
        let reading = AgentDiffLines("--- /a.swift\n+++ /a.swift\n context\n-old\n+new\n+newer\n")
        #expect(reading.path == "/a.swift")
        #expect(reading.added == 2)
        #expect(reading.removed == 1)
    }

    @Test func headerPairIsNotTwoDiffLines() {
        let reading = AgentDiffLines("--- /a\n+++ /a\n+x")
        #expect(reading.lines == [AgentDiffLines.Line(kind: .added, text: "x")])
    }

    @Test func markerIsStrippedFromChangesButNotContext() {
        let reading = AgentDiffLines("-gone\n+here\n kept")
        #expect(reading.lines.map(\.text) == ["gone", "here", " kept"])
        #expect(reading.lines.map(\.kind) == [.removed, .added, .context])
    }

    @Test func noHeaderMeansNoPath() {
        #expect(AgentDiffLines("-a\n+b\n").path == nil)
    }

    @Test func roundTripsWhatTheHostWrites() {
        let diff = AgentDiff.replacement(old: "one\ntwo", new: "one\nthree", path: "/f")
        let reading = AgentDiffLines(diff)
        #expect(reading.path == "/f")
        #expect(reading.added == 2)
        #expect(reading.removed == 2)
    }
}
