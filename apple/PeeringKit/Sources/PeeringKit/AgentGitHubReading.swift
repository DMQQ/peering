import Foundation
import RemoteCore

/// Reading what `gh` prints about a branch, and the fixed argument lists the Mac runs.
public enum AgentGitHubReading {
    public static let runLimit = 5

    public static let pullRequestFields = "number,title,url,state,isDraft,mergeable,reviewDecision,headRefOid,statusCheckRollup"
    public static let runFields = "databaseId,workflowName,displayTitle,status,conclusion,url"

    public static let missingMessage = "The GitHub CLI (gh) is not installed on this Mac. Install it with Homebrew: brew install gh."

    public static var pullRequestArguments: [String] { ["pr", "view", "--json", pullRequestFields] }

    /// Nil for a branch name that could be read as a flag or is not a plain ref.
    public static func runArguments(branch: String) -> [String]? {
        guard AgentGitPush.isPlainRefName(branch) else { return nil }
        return ["run", "list", "--branch", branch, "--limit", String(runLimit), "--json", runFields]
    }

    /// No flag that bypasses review or protection (`--admin`), queues for later (`--auto`) or deletes anything.
    public static func arguments(for action: AgentGitHubAction) -> [String]? {
        switch action {
        case .createPullRequest(let draft):
            return ["pr", "create", "--fill"] + (draft ? ["--draft"] : [])
        case .merge(let number, let headCommit, let method):
            guard number > 0, isCommitHash(headCommit) else { return nil }
            return ["pr", "merge", String(number), "--\(method.rawValue)", "--match-head-commit", headCommit]
        case .rerunFailedJobs(let runID):
            guard runID > 0 else { return nil }
            return ["run", "rerun", String(runID), "--failed"]
        }
    }

    static func isCommitHash(_ text: String) -> Bool {
        (7...64).contains(text.count) && text.allSatisfy(\.isHexDigit)
    }

    // MARK: - Output

    public enum PullRequestRead: Equatable, Sendable {
        case found(AgentGitHubPullRequest)
        case none
        case problem(String)
    }

    public static func pullRequest(succeeded: Bool, output: String) -> PullRequestRead {
        guard succeeded else {
            if output.lowercased().contains("no pull requests found") { return .none }
            return .problem(problem(in: output))
        }
        guard let data = json(in: output, opening: "{"),
              let decoded = try? JSONDecoder().decode(PullRequestJSON.self, from: data)
        else { return .problem("gh answered in a shape this Mac does not read.") }
        return .found(decoded.pullRequest)
    }

    public static func runs(output: String) -> [AgentGitHubRun] {
        guard let data = json(in: output, opening: "["), let decoded = try? JSONDecoder().decode([RunJSON].self, from: data) else { return [] }
        return decoded.prefix(runLimit).map(\.run)
    }

    /// The Mac reads gh's error text in the same stream, so a warning may come before the JSON.
    private static func json(in output: String, opening: Character) -> Data? {
        guard let start = output.firstIndex(of: opening) else { return nil }
        return Data(output[start...].utf8)
    }

    /// The one line the phone shows for a read that failed.
    public static func problem(in output: String) -> String {
        let lowered = output.lowercased()
        if lowered.contains("gh auth login") || lowered.contains("not logged in") || lowered.contains("authentication") {
            return "gh on this Mac is not signed in to GitHub. Run gh auth login there once."
        }
        if lowered.contains("none of the git remotes") || lowered.contains("no git remotes") {
            return "This folder has no remote on GitHub."
        }
        if lowered.contains("not a git repository") {
            return "This folder is not in a git repository."
        }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "gh stopped without saying why." : String(text.suffix(AgentGitOutcome.maximumMessageLength))
    }

    public static func result(for action: AgentGitHubAction, succeeded: Bool, output: String) -> AgentGitHubResult {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let message: String
        if succeeded {
            message = text.isEmpty ? "Done." : String(text.prefix(AgentGitOutcome.maximumMessageLength))
        } else if text.lowercased().contains("head branch was modified") {
            message = "The branch has new commits since you looked, so nothing was merged. Look again and merge if it is still right."
        } else {
            message = problem(in: text)
        }
        return AgentGitHubResult(action: action, succeeded: succeeded, message: message)
    }
}

// MARK: - gh's JSON

private struct PullRequestJSON: Decodable {
    struct Check: Decodable {
        let typename: String?
        let status: String?
        let conclusion: String?
        let state: String?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename", status, conclusion, state
        }
    }

    let number: Int
    let title: String
    let url: String
    let state: String
    let isDraft: Bool?
    let mergeable: String?
    let reviewDecision: String?
    let headRefOid: String
    let statusCheckRollup: [Check]?

    var pullRequest: AgentGitHubPullRequest {
        AgentGitHubPullRequest(
            number: number, title: title, url: url, state: state, isDraft: isDraft ?? false, mergeable: mergeable ?? "UNKNOWN",
            reviewDecision: reviewDecision?.isEmpty == false ? reviewDecision : nil, headCommit: headRefOid,
            checks: Self.tally(statusCheckRollup ?? [])
        )
    }

    /// A check run carries status and conclusion; a commit status carries only a state.
    static func tally(_ checks: [Check]) -> AgentGitHubChecks {
        var passed = 0, failed = 0, pending = 0
        for check in checks {
            let verdict: String?
            if let state = check.state, check.status == nil {
                verdict = state == "PENDING" || state == "EXPECTED" ? nil : state
            } else {
                verdict = check.status == "COMPLETED" ? (check.conclusion ?? "") : nil
            }
            switch verdict {
            case nil: pending += 1
            case "SUCCESS", "NEUTRAL", "SKIPPED": passed += 1
            default: failed += 1
            }
        }
        return AgentGitHubChecks(passed: passed, failed: failed, pending: pending)
    }
}

private struct RunJSON: Decodable {
    let databaseId: Int64
    let workflowName: String?
    let displayTitle: String?
    let status: String
    let conclusion: String?
    let url: String

    var run: AgentGitHubRun {
        AgentGitHubRun(
            id: databaseId, name: workflowName ?? "", title: displayTitle ?? "", status: status,
            conclusion: conclusion?.isEmpty == false ? conclusion : nil, url: url
        )
    }
}
