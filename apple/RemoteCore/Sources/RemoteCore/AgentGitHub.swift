import Foundation

/// A session folder's branch as GitHub sees it, read on the Mac through its signed-in `gh`.
///
/// States and conclusions stay strings as GitHub spells them (`OPEN`, `FAILURE`), so a value GitHub adds later still decodes.
public struct AgentGitHubReport: Codable, Equatable, Sendable {
    /// Why nothing could be read; nil when the read worked, even with no pull request.
    public let problem: String?
    public let branch: String?
    public let pullRequest: AgentGitHubPullRequest?
    /// The branch's latest workflow runs, newest first.
    public let runs: [AgentGitHubRun]

    public init(problem: String?, branch: String?, pullRequest: AgentGitHubPullRequest?, runs: [AgentGitHubRun]) {
        self.problem = problem
        self.branch = branch
        self.pullRequest = pullRequest
        self.runs = runs
    }

    public static func failure(_ problem: String) -> Self {
        Self(problem: problem, branch: nil, pullRequest: nil, runs: [])
    }
}

public struct AgentGitHubPullRequest: Codable, Equatable, Sendable {
    public let number: Int
    public let title: String
    public let url: String
    public let state: String
    public let isDraft: Bool
    /// `MERGEABLE`, `CONFLICTING` or `UNKNOWN` while GitHub is still working it out.
    public let mergeable: String
    public let reviewDecision: String?
    /// The commit the phone saw; a merge names it so the Mac refuses one the branch has moved past.
    public let headCommit: String
    public let checks: AgentGitHubChecks

    public init(
        number: Int, title: String, url: String, state: String, isDraft: Bool, mergeable: String,
        reviewDecision: String?, headCommit: String, checks: AgentGitHubChecks
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.mergeable = mergeable
        self.reviewDecision = reviewDecision
        self.headCommit = headCommit
        self.checks = checks
    }
}

public struct AgentGitHubChecks: Codable, Equatable, Sendable {
    public let passed: Int
    public let failed: Int
    public let pending: Int

    public init(passed: Int, failed: Int, pending: Int) {
        self.passed = passed
        self.failed = failed
        self.pending = pending
    }
}

public struct AgentGitHubRun: Codable, Equatable, Sendable, Identifiable {
    public let id: Int64
    public let name: String
    public let title: String
    /// `queued`, `in_progress`, `completed` and the like.
    public let status: String
    /// Set once completed: `success`, `failure`, `cancelled` and the like.
    public let conclusion: String?
    public let url: String

    public init(id: Int64, name: String, title: String, status: String, conclusion: String?, url: String) {
        self.id = id
        self.name = name
        self.title = title
        self.status = status
        self.conclusion = conclusion
        self.url = url
    }
}

public enum AgentGitHubMergeMethod: String, Codable, Equatable, Sendable, CaseIterable {
    case squash, merge, rebase
}

/// What the phone may ask `gh` to do. The Mac builds every argument list itself; the phone only picks one of these.
public enum AgentGitHubAction: Codable, Equatable, Sendable {
    /// A pull request for the current branch, titled and described from its commits.
    case createPullRequest(draft: Bool)
    /// Refused when the pull request's head is no longer ``headCommit``.
    case merge(number: Int, headCommit: String, method: AgentGitHubMergeMethod)
    case rerunFailedJobs(runID: Int64)
}

public struct AgentGitHubResult: Codable, Equatable, Sendable {
    public let action: AgentGitHubAction
    public let succeeded: Bool
    public let message: String

    public init(action: AgentGitHubAction, succeeded: Bool, message: String) {
        self.action = action
        self.succeeded = succeeded
        self.message = message
    }
}
