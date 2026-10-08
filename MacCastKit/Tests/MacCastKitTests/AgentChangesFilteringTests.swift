import Foundation
import RemoteCore
import Testing

@testable import MacCastKit

private func changed(_ path: String, kind: AgentChangeKind = .modified, added: Int = 1, removed: Int = 0) -> AgentChangedFile {
    AgentChangedFile(path: path, kind: kind, added: added, removed: removed, diff: "+a")
}

private func report(files: [AgentChangedFile], paths: [String] = []) -> AgentChangesReport {
    AgentChangesReport(isRepository: true, files: files, paths: paths, truncated: false)
}

private func rowIDs(_ overview: AgentChangeOverview, open: Bool = true) -> [String] {
    overview.tree.rows(expanded: open ? overview.tree.allFolders : []).map(\.id)
}

struct AgentChangesFilteringTests {
    @Test func dotFoldersLeaveTheFlatListByDefault() {
        let overview = AgentChangeOverview(
            report: report(files: [changed("src/a.swift"), changed(".claude/settings.json"), changed("web/.cache/x")]), edits: []
        )
        #expect(overview.entries.map(\.path) == ["src/a.swift"])
        #expect(overview.hiddenCount == 2)
    }

    @Test func dotFoldersLeaveTheTreeAndFoldersWithNothingVisibleDisappear() {
        let overview = AgentChangeOverview(
            report: report(
                files: [changed("src/a.swift"), changed(".claude/settings.json")],
                paths: ["src/a.swift", "src/b.swift", ".claude/settings.json", ".claude/notes.md", "web/.cache/x"]
            ),
            edits: []
        )
        let ids = rowIDs(overview)
        #expect(ids == ["src", "src/a.swift", "src/b.swift"])
    }

    @Test func foldersLoseTheirHiddenFilesFromTheirCounts() {
        let overview = AgentChangeOverview(
            report: report(files: [changed("src/a.swift"), changed("src/.gen/b.swift")], paths: ["src/a.swift", "src/.gen/b.swift"]),
            edits: []
        )
        let src = overview.tree.rows(expanded: []).first { $0.id == "src" }
        #expect(src?.changedCount == 1)
    }

    @Test func totalsCountOnlyWhatIsShown() {
        let overview = AgentChangeOverview(
            report: report(files: [changed("a.swift", added: 4, removed: 1), changed(".skills/x.md", added: 900, removed: 90)]), edits: []
        )
        #expect(overview.added == 4)
        #expect(overview.removed == 1)
        #expect(overview.entries.count == 1)
    }

    @Test func showingHiddenFoldersBringsThemBack() {
        var filter = AgentReviewFilter()
        filter.hidesHiddenFolders = false
        let overview = AgentChangeOverview(report: report(files: [changed(".claude/a")]), edits: [], filter: filter)
        #expect(overview.entries.count == 1)
        #expect(overview.hiddenCount == 0)
    }

    @Test func searchNarrowsBothModesButNotTheHiddenCount() {
        let overview = AgentChangeOverview(
            report: report(
                files: [changed("src/Login.swift"), changed("src/Chat.swift"), changed(".claude/x")],
                paths: ["src/Login.swift", "src/Chat.swift", "docs/readme.md", ".claude/x"]
            ),
            edits: [], search: "login"
        )
        #expect(overview.entries.map(\.path) == ["src/Login.swift"])
        #expect(rowIDs(overview) == ["src", "src/Login.swift"])
        #expect(overview.hiddenCount == 1)
    }

    @Test func onlyAgentEditedKeepsTheSparkleSet() {
        var filter = AgentReviewFilter()
        filter.onlyAgentEdited = true
        let overview = AgentChangeOverview(
            report: report(files: [changed("mine.swift"), changed("theirs.swift")], paths: ["mine.swift", "theirs.swift", "other.swift"]),
            edits: [AgentFileEdit(path: "mine.swift"), AgentFileEdit(path: "only-transcript.swift")],
            filter: filter
        )
        #expect(overview.entries.map(\.path) == ["mine.swift", "only-transcript.swift"])
        #expect(overview.hiddenCount == 1)
        #expect(rowIDs(overview) == ["mine.swift", "only-transcript.swift"])
    }

    @Test func theAgentRuleIsOffByDefaultAndIgnoredWhereNoTranscriptIsRead() {
        var filter = AgentReviewFilter()
        #expect(!filter.onlyAgentEdited)
        filter.onlyAgentEdited = true
        #expect(filter.shows(changed("a.swift")))
        #expect(!filter.shows(changed("a.swift"), editedByAgent: false))
        #expect(filter.shows(changed("a.swift"), editedByAgent: true))
        #expect(!filter.isDefault)
        #expect(filter.isDefaultIgnoringAgentRule)
    }

    @Test func aKindChipLeavesTranscriptOnlyEditsAlone() {
        var filter = AgentReviewFilter()
        for kind in [AgentChangeKind.modified, .added, .deleted, .untracked] { filter.toggle(kind) }
        let overview = AgentChangeOverview(
            report: report(files: [changed("a.swift")]), edits: [AgentFileEdit(path: "b.swift")], filter: filter
        )
        #expect(overview.entries.map(\.path) == ["b.swift"])
    }

    @Test func filtersSavedBeforeTheAgentRuleExistedStillDecode() throws {
        let old = #"{"hidesHiddenFolders":false,"showsUntracked":true,"kinds":["modified"],"hiddenPatterns":["x"]}"#
        let filter = try JSONDecoder().decode(AgentReviewFilter.self, from: Data(old.utf8))
        #expect(!filter.hidesHiddenFolders)
        #expect(!filter.onlyAgentEdited)
        #expect(filter.hiddenPatterns == ["x"])
    }
}

struct AgentCommitSelectionTests {
    private let files = [changed("src/a.swift"), changed(".claude/settings.json", kind: .untracked), changed("b.swift")]
    private let filter = AgentReviewFilter()

    private func chosen(_ selection: AgentCommitSelection) -> [String] {
        selection.chosen(from: files) { !filter.shows($0) }.map(\.path)
    }

    @Test func hiddenFilesAreNotTickedByDefault() {
        #expect(chosen(AgentCommitSelection()) == ["src/a.swift", "b.swift"])
    }

    @Test func aHiddenFileIsCommittedOnlyAfterTheUserTicksIt() {
        var selection = AgentCommitSelection()
        selection.toggle(files[1], hidden: true)
        #expect(chosen(selection) == ["src/a.swift", ".claude/settings.json", "b.swift"])
        selection.toggle(files[1], hidden: true)
        #expect(chosen(selection) == ["src/a.swift", "b.swift"])
    }

    @Test func untickingAVisibleFileDropsIt() {
        var selection = AgentCommitSelection()
        selection.toggle(files[0], hidden: false)
        #expect(chosen(selection) == ["b.swift"])
    }

    @Test func resetReturnsToTheDefaults() {
        var selection = AgentCommitSelection()
        selection.toggle(files[1], hidden: true)
        selection.toggle(files[2], hidden: false)
        selection.reset()
        #expect(chosen(selection) == ["src/a.swift", "b.swift"])
    }

    @Test func theAgentRuleHidesUneditedFilesFromTheDefault() {
        var agentOnly = AgentReviewFilter()
        agentOnly.onlyAgentEdited = true
        let edited: Set<String> = ["b.swift"]
        let picked = AgentCommitSelection().chosen(from: files) { !agentOnly.shows($0, editedByAgent: edited.contains($0.path)) }
        #expect(picked.map(\.path) == ["b.swift"])
    }
}
