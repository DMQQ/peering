import Foundation
import RemoteCore
import Testing
@testable import PeeringKit

struct AgentGitHubReadingTests {
    private let pullRequestJSON = """
    {"number":42,"title":"Add the thing","url":"https://github.com/o/r/pull/42","state":"OPEN","isDraft":false,
     "mergeable":"MERGEABLE","reviewDecision":"","headRefOid":"0123abcd0123abcd0123abcd0123abcd0123abcd",
     "statusCheckRollup":[
       {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
       {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"},
       {"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"},
       {"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":""},
       {"__typename":"StatusContext","state":"PENDING"},
       {"__typename":"StatusContext","state":"ERROR"}
     ]}
    """

    @Test func readsAPullRequestAndTalliesItsChecks() throws {
        guard case .found(let pullRequest) = AgentGitHubReading.pullRequest(succeeded: true, output: pullRequestJSON) else {
            Issue.record("expected a pull request")
            return
        }
        #expect(pullRequest.number == 42)
        #expect(pullRequest.reviewDecision == nil)
        #expect(pullRequest.checks == AgentGitHubChecks(passed: 2, failed: 2, pending: 2))
        #expect(AgentGitHubOffer.canMerge(pullRequest))
    }

    @Test func aBranchWithoutAPullRequestIsNotAProblem() {
        let read = AgentGitHubReading.pullRequest(succeeded: false, output: "no pull requests found for branch \"feature\"")
        #expect(read == .none)
    }

    @Test func anUnsignedGhSaysSo() {
        let read = AgentGitHubReading.pullRequest(succeeded: false, output: "To get started with GitHub CLI, please run:  gh auth login")
        #expect(read == .problem("gh on this Mac is not signed in to GitHub. Run gh auth login there once."))
    }

    @Test func readsRunsAndDropsAnEmptyConclusion() {
        let output = """
        [{"databaseId":7,"workflowName":"CI","displayTitle":"Fix","status":"in_progress","conclusion":"","url":"u"},
         {"databaseId":6,"workflowName":"CI","displayTitle":"Fix","status":"completed","conclusion":"failure","url":"u"}]
        """
        let runs = AgentGitHubReading.runs(output: output)
        #expect(runs.map(\.id) == [7, 6])
        #expect(runs[0].conclusion == nil)
        #expect(!AgentGitHubOffer.canRerun(runs[0]))
        #expect(AgentGitHubOffer.canRerun(runs[1]))
        #expect(AgentGitHubOffer.tone(of: runs[1]) == .failed)
    }

    @Test func mergeNamesTheHeadItSawAndNeverBypassesProtection() {
        let arguments = AgentGitHubReading.arguments(for: .merge(number: 42, headCommit: "0123abcd", method: .squash))
        #expect(arguments == ["pr", "merge", "42", "--squash", "--match-head-commit", "0123abcd"])
        #expect(arguments?.contains("--admin") == false)
    }

    @Test func refusesAHeadThatIsNotAHash() {
        #expect(AgentGitHubReading.arguments(for: .merge(number: 1, headCommit: "--admin", method: .merge)) == nil)
        #expect(AgentGitHubReading.arguments(for: .rerunFailedJobs(runID: -3)) == nil)
    }

    @Test func refusesABranchThatReadsAsAFlag() {
        #expect(AgentGitHubReading.runArguments(branch: "-x") == nil)
        #expect(AgentGitHubReading.runArguments(branch: "feature/a")?.contains("feature/a") == true)
    }

    @Test func aDraftOrConflictingPullRequestIsNotOfferedForMerge() throws {
        let draft = pullRequestJSON.replacingOccurrences(of: "\"isDraft\":false", with: "\"isDraft\":true")
        guard case .found(let pullRequest) = AgentGitHubReading.pullRequest(succeeded: true, output: draft) else {
            Issue.record("expected a pull request")
            return
        }
        #expect(!AgentGitHubOffer.canMerge(pullRequest))
    }

    @Test func aMovedBranchExplainsWhyNothingMerged() {
        let action = AgentGitHubAction.merge(number: 1, headCommit: "abcdef0", method: .squash)
        let result = AgentGitHubReading.result(for: action, succeeded: false, output: "GraphQL: Head branch was modified. Review and try the merge again.")
        #expect(result.message.hasPrefix("The branch has new commits"))
    }

    @Test func anUnrelatedFailureNamingTheFlagIsNotCalledARace() {
        let action = AgentGitHubAction.merge(number: 1, headCommit: "abcdef0", method: .squash)
        let result = AgentGitHubReading.result(for: action, succeeded: false, output: "unknown flag: --match-head-commit")
        #expect(!result.message.hasPrefix("The branch has new commits"))
    }

    @Test func aSuccessKeepsGhsOwnWords() {
        let result = AgentGitHubReading.result(for: .rerunFailedJobs(runID: 3), succeeded: true, output: "Requested rerun\n")
        #expect(result.succeeded)
        #expect(result.message == "Requested rerun")
    }

    @Test func aCancelledRunIsOfferedARerunButNotShownAsFailed() {
        let run = AgentGitHubRun(id: 1, name: "CI", title: "t", status: "completed", conclusion: "cancelled", url: "u")
        #expect(AgentGitHubOffer.canRerun(run))
        #expect(AgentGitHubOffer.tone(of: run) == .other)
    }

    @Test func aConflictingPullRequestWithFailingChecksSaysBoth() {
        let pullRequest = AgentGitHubPullRequest(
            number: 1, title: "t", url: "u", state: "OPEN", isDraft: false, mergeable: "CONFLICTING",
            reviewDecision: "APPROVED", headCommit: "abcdef0", checks: AgentGitHubChecks(passed: 3, failed: 1, pending: 0)
        )
        #expect(AgentGitHubOffer.facts(about: pullRequest) == [.conflicting, .checksFailing(1), .approved])
    }

    @Test func aMergedPullRequestWithGreenChecksSaysSo() {
        let pullRequest = AgentGitHubPullRequest(
            number: 1, title: "t", url: "u", state: "MERGED", isDraft: false, mergeable: "UNKNOWN",
            reviewDecision: nil, headCommit: "abcdef0", checks: AgentGitHubChecks(passed: 2, failed: 0, pending: 0)
        )
        #expect(AgentGitHubOffer.facts(about: pullRequest) == [.merged, .checksPassed])
    }

    @Test func aPullRequestIsOfferedOnlyForABranchWithoutOne() {
        let empty = AgentGitHubReport(problem: nil, branch: "feature", pullRequest: nil, runs: [])
        #expect(AgentGitHubOffer.canCreatePullRequest(empty))
        #expect(!AgentGitHubOffer.canCreatePullRequest(.failure("no gh")))
    }

    @Test func theWireRoundTripsAnAction() throws {
        let request = AgentRequest.githubAction(sessionID: UUID(), action: .rerunFailedJobs(runID: 9))
        let decoded = try JSONDecoder().decode(AgentRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
    }
}
