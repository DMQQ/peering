import Foundation
import RemoteCore

/// Which GitHub actions the phone offers for what the Mac read.
public enum AgentGitHubOffer {
    /// Conclusions that mean a run did not get through; a re-run of its failed jobs is worth offering.
    private static let unsuccessfulConclusions: Set<String> = ["failure", "cancelled", "timed_out", "startup_failure"]

    public static func canCreatePullRequest(_ report: AgentGitHubReport) -> Bool {
        report.problem == nil && report.branch != nil && report.pullRequest == nil
    }

    /// Open, not a draft, and GitHub says it merges cleanly. Failing checks are shown, not enforced: branch protection is GitHub's to apply.
    public static func canMerge(_ pullRequest: AgentGitHubPullRequest) -> Bool {
        pullRequest.state == "OPEN" && !pullRequest.isDraft && pullRequest.mergeable == "MERGEABLE"
    }

    public static func canRerun(_ run: AgentGitHubRun) -> Bool {
        run.status == "completed" && unsuccessfulConclusions.contains(run.conclusion ?? "")
    }

    /// What a pull request's status line says, most important first.
    public enum Fact: Equatable, Sendable {
        case merged, closed, draft, conflicting
        case checksFailing(Int), checksRunning(Int), checksPassed
        case approved, changesRequested
    }

    public static func facts(about pullRequest: AgentGitHubPullRequest) -> [Fact] {
        var facts: [Fact] = []
        switch pullRequest.state {
        case "MERGED": facts.append(.merged)
        case "CLOSED": facts.append(.closed)
        default:
            if pullRequest.isDraft { facts.append(.draft) } else if pullRequest.mergeable == "CONFLICTING" { facts.append(.conflicting) }
        }
        let checks = pullRequest.checks
        if checks.failed > 0 { facts.append(.checksFailing(checks.failed)) }
        if checks.pending > 0 { facts.append(.checksRunning(checks.pending)) }
        if checks.passed > 0 && checks.failed == 0 && checks.pending == 0 { facts.append(.checksPassed) }
        switch pullRequest.reviewDecision {
        case "APPROVED": facts.append(.approved)
        case "CHANGES_REQUESTED": facts.append(.changesRequested)
        default: break
        }
        return facts
    }

    public enum RunTone: Equatable, Sendable {
        case passed, failed, running, other
    }

    public static func tone(of run: AgentGitHubRun) -> RunTone {
        guard run.status == "completed" else { return .running }
        if run.conclusion == "success" { return .passed }
        return run.conclusion == "cancelled" || !unsuccessfulConclusions.contains(run.conclusion ?? "") ? .other : .failed
    }
}
