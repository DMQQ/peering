import Foundation
import RemoteCore
import Testing

@testable import PeeringKit

private func file(_ path: String, kind: AgentChangeKind = .modified, added: Int = 1, removed: Int = 0, diff: String? = "+a") -> AgentChangedFile {
    AgentChangedFile(path: path, kind: kind, added: added, removed: removed, diff: diff)
}

private func queue(_ files: [AgentChangedFile], filter: AgentReviewFilter = AgentReviewFilter(), search: String = "") -> AgentReviewQueue {
    let report = AgentChangesReport(isRepository: true, files: files, paths: [], truncated: false)
    let source = AgentReviewSource(chatID: UUID(), title: "Chat", directory: "/p", report: report, isReachable: true)
    return AgentReviewQueue(sources: [source], marks: AgentReviewMarks(), filter: filter, search: search)
}

struct AgentChangeStatsTests {
    @Test func sumsLinesAndGroupsThousands() {
        let stats = AgentChangeStats(files: [file("a", added: 3000, removed: 900), file("b", added: 402, removed: 81)])
        let us = Locale(identifier: "en_US")
        #expect(stats.fileCount == 2)
        #expect(stats.addedText(locale: us) == "+3,402")
        #expect(stats.removedText(locale: us) == "-981")
    }

    @Test func skipsFilesWhoseCountsAreUnknown() {
        let stats = AgentChangeStats(files: [file("a", added: 5, removed: 2), file("bin", added: 0, removed: 0, diff: nil)])
        #expect(stats.fileCount == 2)
        #expect(stats.added == 5)
        #expect(stats.removed == 2)
    }
}

struct AgentReviewFilterTests {
    @Test func hiddenFoldersAreHiddenByDefaultAnywhereInThePath() {
        let filter = AgentReviewFilter()
        #expect(!filter.shows(file(".skills/a.md")))
        #expect(!filter.shows(file("src/.claude/x")))
        #expect(!filter.shows(file(".env")))
        #expect(filter.shows(file("src/a.swift")))
    }

    @Test func hiddenFoldersReturnWhenTheToggleIsOff() {
        var filter = AgentReviewFilter()
        filter.hidesHiddenFolders = false
        #expect(filter.shows(file(".skills/a.md")))
    }

    @Test func untrackedFilesCanBeSwitchedOff() {
        var filter = AgentReviewFilter()
        filter.showsUntracked = false
        #expect(!filter.shows(file("new.swift", kind: .untracked)))
        #expect(filter.shows(file("old.swift")))
    }

    @Test func aKindChipHidesThatKind() {
        var filter = AgentReviewFilter()
        filter.toggle(.deleted)
        #expect(!filter.shows(file("gone.swift", kind: .deleted)))
        filter.toggle(.deleted)
        #expect(filter.shows(file("gone.swift", kind: .deleted)))
    }

    @Test func aPatternHidesMatchingPathsIgnoringCase() {
        var filter = AgentReviewFilter()
        filter.addPattern(" Node_Modules ")
        filter.addPattern("node_modules")
        #expect(filter.hiddenPatterns == ["Node_Modules"])
        #expect(!filter.shows(file("web/node_modules/x.js")))
        filter.removePattern("Node_Modules")
        #expect(filter.shows(file("web/node_modules/x.js")))
    }

    @Test func searchNarrowsByPath() {
        #expect(AgentReviewFilter.matches(file("src/Login.swift"), search: "login"))
        #expect(!AgentReviewFilter.matches(file("src/Login.swift"), search: "chat"))
        #expect(AgentReviewFilter.matches(file("src/Login.swift"), search: "  "))
    }

    @Test func settingsSurviveEncoding() throws {
        var filter = AgentReviewFilter()
        filter.hidesHiddenFolders = false
        filter.addPattern(".skills")
        filter.toggle(.added)
        let decoded = try JSONDecoder().decode(AgentReviewFilter.self, from: JSONEncoder().encode(filter))
        #expect(decoded == filter)
    }
}

struct AgentReviewQueueFilteringTests {
    @Test func hiddenFilesAreNotPendingAndAreCounted() {
        let q = queue([file("a.swift"), file(".skills/x.md", kind: .untracked), file(".agents/y.md", kind: .untracked)])
        #expect(q.pendingFileCount == 1)
        #expect(q.hiddenFileCount == 2)
        #expect(q.groups[0].files.count == 1)
    }

    @Test func totalsLeaveOutHiddenFiles() {
        let q = queue([file("a.swift", added: 4, removed: 1), file(".skills/x.md", added: 900)])
        #expect(q.pendingStats.added == 4)
        #expect(q.pendingStats.removed == 1)
    }

    @Test func aChatWithOnlyHiddenFilesIsNotListedOrCounted() {
        let q = queue([file(".claude/x", kind: .untracked)])
        #expect(q.pendingChatCount == 0)
        #expect(q.visibleGroups.isEmpty)
    }

    @Test func searchNarrowsTheListButNotTheHiddenCount() {
        let q = queue([file("a.swift"), file("b.swift"), file(".x/c")], search: "a.sw")
        #expect(q.groups[0].files.count == 1)
        #expect(q.hiddenFileCount == 1)
    }
}
