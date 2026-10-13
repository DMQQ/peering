import Foundation
import RemoteCore
import Testing

@testable import MacCastKit

private let patch = """
diff --git a/Sources/A.swift b/Sources/A.swift
index 111..222 100644
--- a/Sources/A.swift
+++ b/Sources/A.swift
@@ -1,3 +1,4 @@
 let a = 1
-let b = 2
+let b = 3
+let c = 4
 let d = 5
diff --git a/my file.txt b/my file.txt
new file mode 100644
index 000..333
--- /dev/null
+++ b/my file.txt\t
@@ -0,0 +1,2 @@
+one
+two
diff --git a/old.txt b/old.txt
deleted file mode 100644
index 444..000
--- a/old.txt
+++ /dev/null
@@ -1 +0,0 @@
-gone
diff --git a/logo.png b/logo.png
index 555..666 100644
Binary files a/logo.png and b/logo.png differ
"""

@Suite struct AgentGitDiffTests {
    @Test func eachFileGetsItsOwnKindAndCounts() {
        let files = AgentGitDiff.files(in: patch.replacingOccurrences(of: "\\t", with: "\t"))
        #expect(files.map(\.path) == ["Sources/A.swift", "my file.txt", "old.txt", "logo.png"])
        #expect(files.map(\.kind) == [.modified, .added, .deleted, .modified])
        #expect(files[0].added == 2)
        #expect(files[0].removed == 1)
        #expect(files[2].removed == 1)
    }

    @Test func aBinaryFileHasNoDiff() {
        let files = AgentGitDiff.files(in: patch)
        #expect(files[3].diff == nil)
    }

    @Test func aLargeDiffIsCutButStillCounted() {
        let body = (0..<500).map { "+line \($0)" }.joined(separator: "\n")
        let big = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -0,0 +1,500 @@\n" + body
        let file = AgentGitDiff.files(in: big, perFileLimit: 400)[0]
        #expect(file.added == 500)
        #expect(file.diff?.hasSuffix(AgentGitDiff.truncationNote) == true)
    }

    @Test func anUntrackedFileReadsAsAllAdded() {
        let file = AgentGitDiff.untracked(path: "new.txt", content: "a\nb\n")
        #expect(file.kind == .untracked)
        #expect(file.added == 2)
        let reading = AgentReviewDiff(file.diff ?? "")
        #expect(reading.lines.map(\.newNumber) == [nil, 1, 2])
    }

    @Test func nothingPrintedMeansNoFiles() {
        #expect(AgentGitDiff.files(in: "").isEmpty)
    }
}

@Suite struct AgentReviewDiffTests {
    @Test func linesAreNumberedFromTheHunkHeader() {
        let reading = AgentReviewDiff(AgentGitDiff.files(in: patch)[0].diff ?? "")
        let kinds = reading.lines.map(\.kind)
        #expect(kinds == [.hunk, .context, .removed, .added, .added, .context])
        #expect(reading.lines.map(\.newNumber) == [nil, 1, nil, 2, 3, 4])
        #expect(reading.lines.map(\.oldNumber) == [nil, 1, 2, nil, nil, 3])
    }

    @Test func aHunkHeaderIsNotCommentable() {
        let reading = AgentReviewDiff("@@ -5,1 +9,1 @@\n x")
        #expect(reading.lines[0].isCommentable == false)
        #expect(reading.lines[1].newNumber == 9)
        #expect(reading.lines[1].text == "x")
    }

    @Test func theNoNewlineMarkerIsNotALine() {
        let reading = AgentReviewDiff("@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b")
        #expect(reading.lines.count == 3)
    }
}

@Suite struct AgentChangePathTests {
    @Test func onlyRelativePathsInsideTheFolderPass() {
        #expect(AgentChangePath.isInsideFolder("a/b.swift"))
        #expect(!AgentChangePath.isInsideFolder("../secret"))
        #expect(!AgentChangePath.isInsideFolder("a/../../secret"))
        #expect(!AgentChangePath.isInsideFolder("/etc/passwd"))
        #expect(!AgentChangePath.isInsideFolder(""))
        #expect(!AgentChangePath.isInsideFolder("a//b"))
    }
}

@Suite struct AgentChangeTreeTests {
    private let paths = ["README.md", "Sources/App/main.swift", "Sources/Lib/a.swift", "Sources/Lib/b.swift", "Tests/t.swift"]

    @Test func foldersComeFirstAndOnlyOpenOnesShowChildren() {
        let tree = AgentChangeTree(paths: paths, changed: [])
        #expect(tree.rows(expanded: []).map(\.id) == ["Sources", "Tests", "README.md"])
        let open = tree.rows(expanded: ["Sources"])
        #expect(open.map(\.id) == ["Sources", "Sources/App", "Sources/Lib", "Tests", "README.md"])
        #expect(open[1].depth == 1)
    }

    @Test func aFolderCountsTheChangedFilesBeneathIt() {
        let tree = AgentChangeTree(paths: paths, changed: ["Sources/Lib/a.swift", "Sources/Lib/b.swift"])
        let rows = tree.rows(expanded: tree.foldersWithChanges)
        #expect(rows.first { $0.id == "Sources" }?.changedCount == 2)
        #expect(rows.first { $0.id == "Sources/Lib/a.swift" }?.isChanged == true)
        #expect(rows.first { $0.id == "Sources/App" }?.isChanged == false)
        #expect(tree.foldersWithChanges == ["Sources", "Sources/Lib"])
    }

    @Test func aChangedFileMissingFromTheListingIsStillShown() {
        let tree = AgentChangeTree(paths: [], changed: ["gone/old.txt"])
        #expect(tree.rows(expanded: ["gone"]).map(\.id) == ["gone", "gone/old.txt"])
    }
}

@Suite struct AgentChangeSetTests {
    private func transcript(_ calls: [(AgentToolCall, Bool)]) -> AgentTranscript {
        var transcript = AgentTranscript()
        for (call, ok) in calls {
            transcript.apply(.toolStarted(call: call))
            transcript.apply(.toolFinished(callID: call.id, ok: ok, output: nil, truncated: false))
        }
        return transcript
    }

    @Test func onlySuccessfulEditsInsideTheFolderCount() {
        let found = AgentChangeSet.edits(in: transcript([
            (AgentToolCall(id: "1", name: "Edit", title: "Edit", filePath: "/p/a.swift", diff: "-x\n+y"), true),
            (AgentToolCall(id: "2", name: "Read", title: "Read", filePath: "/p/b.swift"), true),
            (AgentToolCall(id: "3", name: "Write", title: "Write", filePath: "/p/c.swift"), false),
            (AgentToolCall(id: "4", name: "Write", title: "Write", filePath: "/elsewhere/d.swift"), true),
            (AgentToolCall(id: "5", name: "Write", title: "Write", filePath: "/p/sub/e.swift"), true),
        ]), directory: "/p")
        #expect(found.map(\.path) == ["a.swift", "sub/e.swift"])
    }

    @Test func gitsDiffWinsAndTheTranscriptAddsWhatGitMissed() {
        let report = AgentChangesReport(
            isRepository: true,
            files: [AgentChangedFile(path: "a.swift", kind: .modified, added: 1, removed: 1, diff: "@@ -1 +1 @@\n-x\n+y")],
            paths: ["a.swift"], truncated: false
        )
        let entries = AgentChangeSet.entries(report: report, edits: [
            AgentFileEdit(path: "a.swift", diff: "-x\n+y"),
            AgentFileEdit(path: "z.swift", diff: "-1\n+2\n+3"),
        ])
        #expect(entries.map(\.path) == ["a.swift", "z.swift"])
        #expect(entries[0].isGitDiff && entries[0].editedByAgent)
        #expect(!entries[1].isGitDiff && entries[1].added == 2 && entries[1].kind == nil)
    }

    @Test func aFileGitChangedOutsideTheAgentIsNotMarkedAsTheAgents() {
        let report = AgentChangesReport(
            isRepository: true,
            files: [AgentChangedFile(path: "b.swift", kind: .untracked, added: 1, removed: 0, diff: nil)],
            paths: [], truncated: false
        )
        #expect(AgentChangeSet.entries(report: report, edits: [])[0].editedByAgent == false)
    }

    @Test func eachKindHasItsLetter() {
        let report = AgentChangesReport(
            isRepository: true,
            files: [AgentChangedFile(path: "a", kind: .deleted, added: 0, removed: 1, diff: nil)],
            paths: [], truncated: false
        )
        let entries = AgentChangeSet.entries(report: report, edits: [AgentFileEdit(path: "b")])
        #expect(entries.map(\.marker) == ["D", "\u{00B7}"])
    }

    @Test func aPathOutsideTheFolderHasNoRelativeForm() {
        #expect(AgentChangeSet.relativePath("/p/a/b.swift", in: "/p/") == "a/b.swift")
        #expect(AgentChangeSet.relativePath("/q/b.swift", in: "/p") == nil)
        #expect(AgentChangeSet.relativePath("../b.swift", in: "/p") == nil)
    }
}

@Suite struct AgentReviewPromptTests {
    @Test func eachCommentIsAPlaceThenAQuoteThenTheRemark() {
        let text = AgentReviewPrompt.text(for: [
            AgentReviewComment(path: "A.swift", line: 12, quote: " let b = 3", text: "Why 3?"),
            AgentReviewComment(path: "B.swift", text: "Split this file."),
            AgentReviewComment(path: "C.swift", line: 4, side: .old, text: "Keep it."),
        ])
        #expect(text.contains("\n\nA.swift:12\n> let b = 3\nWhy 3?"))
        #expect(text.contains("\n\nB.swift\nSplit this file."))
        #expect(text.contains("C.swift:4 (line removed by the change)"))
    }

    @Test func aReviewTooLongForOnePromptSaysWhatItLeftOut() {
        let long = String(repeating: "x", count: 20_000)
        let comments = (0..<5).map { AgentReviewComment(path: "f\($0)", text: long) }
        let text = AgentReviewPrompt.text(for: comments)
        #expect(text.utf8.count <= AgentReviewPrompt.maximumBytes)
        #expect(text.contains("more comments did not fit"))
    }
}

@Suite struct AgentChangesWireTests {
    @Test func theReportSurvivesTheWire() throws {
        let report = AgentChangesReport(
            isRepository: true,
            files: [AgentChangedFile(path: "a", kind: .untracked, added: 1, removed: 0, diff: "d")],
            paths: ["a"], truncated: true, message: nil
        )
        let event = AgentEvent.changes(sessionID: UUID(), report: report)
        let data = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(AgentEvent.self, from: data) == event)
        let request = AgentRequest.changes(sessionID: UUID())
        #expect(try JSONDecoder().decode(AgentRequest.self, from: JSONEncoder().encode(request)) == request)
    }
}

@Suite struct AgentChangeOverviewTests {
    @Test func totalsCoverEveryEntryAndTheTreeMarksThem() {
        let report = AgentChangesReport(
            isRepository: true,
            files: [
                AgentChangedFile(path: "src/a", kind: .modified, added: 3, removed: 1, diff: nil),
                AgentChangedFile(path: "b", kind: .untracked, added: 2, removed: 0, diff: nil),
            ],
            paths: ["src/a", "src/c", "b"], truncated: false
        )
        let overview = AgentChangeOverview(report: report, edits: [])
        #expect(overview.added == 5)
        #expect(overview.removed == 1)
        #expect(overview.entry(at: "b")?.kind == .untracked)
        #expect(overview.tree.rows(expanded: ["src"]).first { $0.id == "src/c" }?.isChanged == false)
    }

    @Test func withoutAReportOnlyTheAgentsEditsShow() {
        let overview = AgentChangeOverview(report: nil, edits: [AgentFileEdit(path: "x/y.swift")])
        #expect(overview.entries.map(\.path) == ["x/y.swift"])
        #expect(overview.tree.rows(expanded: overview.tree.foldersWithChanges).map(\.id) == ["x", "x/y.swift"])
    }
}
