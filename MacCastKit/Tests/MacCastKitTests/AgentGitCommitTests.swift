import Foundation
import RemoteCore
import Testing

@testable import MacCastKit

private func file(_ path: String, _ kind: AgentChangeKind) -> AgentChangedFile {
    AgentChangedFile(path: path, kind: kind, added: 1, removed: 0, diff: nil)
}

@Suite struct AgentCommitDraftTests {
    @Test func oneModifiedFileIsNamed() {
        #expect(AgentCommitDraft.message(for: [file("Sources/A.swift", .modified)]) == "Update A.swift")
    }

    @Test func twoAndThreeFilesAreListed() {
        #expect(AgentCommitDraft.message(for: [file("a/X.swift", .modified), file("b/Y.swift", .modified)]) == "Update X.swift and Y.swift")
        let three = ["X", "Y", "Z"].map { file("\($0).md", .added) }
        #expect(AgentCommitDraft.message(for: three) == "Add X.md, Y.md and Z.md")
    }

    @Test func manyFilesAreCounted() {
        let many = (0..<7).map { file("f\($0).txt", .untracked) }
        #expect(AgentCommitDraft.message(for: many) == "Add 7 files")
    }

    @Test func mixedKindsJoinIntoOneLine() {
        let files = [file("New.swift", .untracked), file("Old.swift", .modified), file("Gone.swift", .deleted)]
        #expect(AgentCommitDraft.message(for: files) == "Add New.swift, update Old.swift and remove Gone.swift")
    }

    @Test func sameNamesFallBackToPaths() {
        let files = [file("a/Index.swift", .modified), file("b/Index.swift", .modified)]
        #expect(AgentCommitDraft.message(for: files) == "Update a/Index.swift and b/Index.swift")
    }

    @Test func noFilesGiveNoMessage() {
        #expect(AgentCommitDraft.message(for: []) == "")
    }

    @Test func theDraftIsOneLineAndHasNoTrailer() {
        let text = AgentCommitDraft.message(for: [file("A.swift", .modified), file("B.swift", .added)])
        #expect(!text.contains("\n"))
        #expect(!text.contains("Co-Authored-By"))
        #expect(!text.contains("\u{2014}"))
    }
}

@Suite struct AgentGitCommitPlanTests {
    @Test func stagesAndCommitsOnlyTheChosenPaths() throws {
        let plan = try AgentGitCommit.plan(paths: ["a.txt", "dir/b.txt"], message: " Update files \n").get()
        #expect(plan.stage == ["--literal-pathspecs", "add", "--", "a.txt", "dir/b.txt"])
        #expect(plan.commit == ["--literal-pathspecs", "commit", "-m", "Update files", "--", "a.txt", "dir/b.txt"])
    }

    @Test func duplicatePathsCollapse() throws {
        let plan = try AgentGitCommit.plan(paths: ["a", "a"], message: "m").get()
        #expect(plan.stage == ["--literal-pathspecs", "add", "--", "a"])
    }

    @Test func emptyFileListAndEmptyMessageAreRefused() {
        #expect(AgentGitCommit.plan(paths: [], message: "m") == .failure(.noFiles))
        #expect(AgentGitCommit.plan(paths: ["a"], message: "  \n ") == .failure(.emptyMessage))
    }

    @Test(arguments: ["../x", "/etc/passwd", "a/../../x", ".git/config", "sub/.git/hooks/pre-commit", ".GIT/x", "a//b", "", "a\0b", "a\nb"])
    func unsafePathsAreRefused(path: String) {
        #expect(AgentGitCommit.plan(paths: ["ok.txt", path], message: "m") == .failure(.unsafePath(path)))
    }

    @Test func aMessageThatLooksLikeAFlagStaysAValue() throws {
        let plan = try AgentGitCommit.plan(paths: ["a"], message: "--amend").get()
        #expect(plan.commit.firstIndex(of: "-m").map { plan.commit[$0 + 1] } == "--amend")
        #expect(!AgentGitForbidden.appears(in: plan.commit))
    }

    @Test func aFileNamedLikeAFlagStaysAfterTheSeparator() throws {
        let plan = try AgentGitCommit.plan(paths: ["--force", "-f"], message: "m").get()
        #expect(plan.stage.prefix(3) == ["--literal-pathspecs", "add", "--"])
        #expect(!AgentGitForbidden.appears(in: plan.stage))
        #expect(!AgentGitForbidden.appears(in: plan.commit))
    }

    @Test func tooManyFilesAreRefused() {
        let many = (0...AgentGitCommit.maximumFiles).map { "f\($0)" }
        #expect(AgentGitCommit.plan(paths: many, message: "m") == .failure(.tooManyFiles))
    }
}

@Suite struct AgentGitPushPlanTests {
    private func branch(
        head: String? = "main", upstream: String? = "origin/main", remote: String? = "origin",
        mergeRef: String? = "refs/heads/main", ahead: Int = 1
    ) -> AgentGitBranch {
        AgentGitBranch(head: head, upstream: upstream, remote: remote, mergeRef: mergeRef, ahead: ahead, behind: 0)
    }

    @Test func thePushIsOneFixedList() throws {
        let arguments = try AgentGitPush.arguments(for: branch()).get()
        #expect(arguments == ["push", "--no-follow-tags", "origin", "refs/heads/main:refs/heads/main"])
    }

    @Test func aRenamedUpstreamIsPushedToItsOwnRef() throws {
        let arguments = try AgentGitPush.arguments(for: branch(mergeRef: "refs/heads/release")).get()
        #expect(arguments.last == "refs/heads/main:refs/heads/release")
    }

    @Test func noPushListCanContainAForceFlagOrAWideningOne() throws {
        let heads = ["main", "feature/a-b", "release-1.2", "x"]
        for head in heads {
            let arguments = try AgentGitPush.arguments(for: branch(head: head, mergeRef: "refs/heads/\(head)")).get()
            #expect(!AgentGitForbidden.appears(in: arguments))
            for flag in ["--force", "-f", "--force-with-lease", "--delete", "--mirror", "--all", "--tags", "--prune", "--no-verify"] {
                #expect(!arguments.contains(flag))
            }
            #expect(!arguments.contains { $0.hasPrefix("+") || $0.contains(":+") })
        }
    }

    @Test(arguments: ["+main", "-f", "--force", "a b", "a:b", "main^", "a..b", "x.lock", "/main", "main/", "ma~in", "ma*in", "a\\b", ""])
    func unusualBranchNamesAreRefused(name: String) {
        if case .success = AgentGitPush.arguments(for: branch(head: name)) { Issue.record("pushed \(name)") }
        if case .success = AgentGitPush.arguments(for: branch(mergeRef: "refs/heads/\(name)")) { Issue.record("pushed to \(name)") }
    }

    @Test(arguments: ["--mirror", "-o", "+origin", "git@host:repo.git", "https://host/repo", ".", "a/b", "a b", ""])
    func remotesThatAreNotPlainNamesAreRefused(remote: String) {
        if case .success = AgentGitPush.arguments(for: branch(remote: remote)) { Issue.record("pushed to \(remote)") }
    }

    @Test func aMergeRefOutsideHeadsIsRefused() {
        #expect(AgentGitPush.arguments(for: branch(mergeRef: "refs/tags/v1")) == .failure(.unsafeBranch))
        #expect(AgentGitPush.arguments(for: branch(mergeRef: "+refs/heads/main")) == .failure(.unsafeBranch))
    }

    @Test func aDetachedHeadIsRefused() {
        #expect(AgentGitPush.arguments(for: branch(head: nil)) == .failure(.detachedHead))
    }

    @Test func aBranchWithNoUpstreamIsRefusedNotGuessed() {
        #expect(AgentGitPush.arguments(for: branch(upstream: nil, remote: nil, mergeRef: nil)) == .failure(.noUpstream))
        #expect(AgentGitPush.arguments(for: branch(remote: nil)) == .failure(.noUpstream))
    }

    @Test func forbiddenFlagsAreRecognised() {
        for list in [["push", "--force"], ["push", "-f"], ["push", "--force-with-lease=x"], ["push", "origin", "+main:main"],
                     ["push", "--delete", "origin"], ["push", "--mirror"], ["push", "--all"], ["push", "--tags"], ["push", "--no-verify"]] {
            #expect(AgentGitForbidden.appears(in: list))
        }
        #expect(!AgentGitForbidden.appears(in: ["push", "origin", "refs/heads/a:refs/heads/a"]))
    }

    @Test func offerSaysWhatCanBePushed() {
        #expect(AgentGitPush.offer(for: branch(ahead: 2)) == .ready(branch: "main", upstream: "origin/main", ahead: 2))
        #expect(AgentGitPush.offer(for: branch(ahead: 0)) == .nothingToPush)
        #expect(AgentGitPush.offer(for: branch(head: nil)) == .blocked(AgentGitRefusal.detachedHead.text))
        #expect(AgentGitPush.offer(for: nil) != .nothingToPush)
    }
}

@Suite struct AgentGitBranchReadingTests {
    @Test func readsHeadUpstreamAndCounts() {
        let status = "# branch.oid abc\n# branch.head main\n# branch.upstream origin/main\n# branch.ab +3 -1\n1 .M N... x"
        let branch = AgentGitPush.branch(statusHeaders: status, remote: "origin", mergeRef: "refs/heads/main")
        #expect(branch == AgentGitBranch(head: "main", upstream: "origin/main", remote: "origin", mergeRef: "refs/heads/main", ahead: 3, behind: 1))
    }

    @Test func detachedAndUnsetAreNil() {
        let detached = AgentGitPush.branch(statusHeaders: "# branch.oid abc\n# branch.head (detached)\n", remote: nil, mergeRef: nil)
        #expect(detached?.head == nil)
        let local = AgentGitPush.branch(statusHeaders: "# branch.oid abc\n# branch.head topic\n", remote: " \n", mergeRef: nil)
        #expect(local?.upstream == nil)
        #expect(local?.remote == nil)
        #expect(AgentGitPush.branch(statusHeaders: "", remote: nil, mergeRef: nil) == nil)
    }
}

@Suite struct AgentGitOutcomeTests {
    @Test func successKeepsGitsSummary() {
        let result = AgentGitOutcome.result(operation: .commit, succeeded: true, output: "[main abc] Update A\n 1 file changed\n")
        #expect(result.succeeded)
        #expect(result.message.hasPrefix("[main abc] Update A"))
    }

    @Test func failureTextIsBoundedAndKeepsItsEnd() {
        let noise = String(repeating: "hook output\n", count: 500)
        let result = AgentGitOutcome.result(operation: .push, succeeded: false, output: noise + "fatal: rejected")
        #expect(!result.succeeded)
        #expect(result.message.count <= AgentGitOutcome.maximumMessageLength + 1)
        #expect(result.message.hasSuffix("fatal: rejected"))
    }

    @Test func aMissingCredentialIsExplained() {
        let result = AgentGitOutcome.result(
            operation: .push, succeeded: false, output: "fatal: could not read Username for 'https://x': terminal prompts disabled"
        )
        #expect(result.message.contains("no saved credential"))
        #expect(result.message.contains("terminal prompts disabled"))
    }

    @Test func silenceStillSaysSomething() {
        #expect(!AgentGitOutcome.result(operation: .push, succeeded: false, output: "").message.isEmpty)
        #expect(AgentGitOutcome.result(operation: .push, succeeded: true, output: "").message == "Pushed.")
    }
}

@Suite struct AgentGitWireTests {
    @Test func commitPushAndTheirAnswersSurviveTheWire() throws {
        let id = UUID()
        let requests: [AgentRequest] = [.commit(sessionID: id, paths: ["a", "b/c"], message: "Update a"), .push(sessionID: id)]
        for request in requests {
            #expect(try JSONDecoder().decode(AgentRequest.self, from: JSONEncoder().encode(request)) == request)
        }
        let branch = AgentGitBranch(head: "main", upstream: "origin/main", remote: "origin", mergeRef: "refs/heads/main", ahead: 1, behind: 0)
        let events: [AgentEvent] = [
            .gitResult(sessionID: id, result: AgentGitResult(operation: .push, succeeded: false, message: "no")),
            .changes(sessionID: id, report: AgentChangesReport(isRepository: true, files: [], paths: [], truncated: false, branch: branch)),
        ]
        for event in events {
            #expect(try JSONDecoder().decode(AgentEvent.self, from: JSONEncoder().encode(event)) == event)
        }
    }

    @Test func aReportFromBeforeBranchesStillDecodes() throws {
        let old = #"{"isRepository":true,"files":[],"paths":[],"truncated":false}"#
        let report = try JSONDecoder().decode(AgentChangesReport.self, from: Data(old.utf8))
        #expect(report.branch == nil)
    }
}
