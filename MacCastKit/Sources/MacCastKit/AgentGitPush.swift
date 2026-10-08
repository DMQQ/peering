import Foundation
import RemoteCore

/// Reading where a branch stands, and the one push the phone may ask for.
public enum AgentGitPush {
    /// From `git status --porcelain=v2 --branch`; ``remote`` and ``mergeRef`` come from the branch's own config.
    public static func branch(statusHeaders output: String, remote: String?, mergeRef: String?) -> AgentGitBranch? {
        var head: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var sawHead = false
        for line in output.split(separator: "\n") where line.hasPrefix("# branch.") {
            let parts = line.dropFirst("# branch.".count).split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "head":
                sawHead = true
                head = parts[1] == "(detached)" ? nil : parts[1]
            case "upstream": upstream = parts[1]
            case "ab":
                let counts = parts[1].split(separator: " ")
                if counts.count == 2 {
                    ahead = Int(counts[0].dropFirst()) ?? 0
                    behind = Int(counts[1].dropFirst()) ?? 0
                }
            default: break
            }
        }
        guard sawHead else { return nil }
        return AgentGitBranch(
            head: head, upstream: upstream, remote: remote?.nonEmpty, mergeRef: mergeRef?.nonEmpty, ahead: ahead, behind: behind
        )
    }

    /// `git push <remote> refs/heads/<branch>:<upstream ref>`: an explicit refspec, so a `remote.<name>.push` setting (which could carry a `+`) is never consulted, and no flag that widens or forces.
    public static func arguments(for branch: AgentGitBranch) -> Result<[String], AgentGitRefusal> {
        guard let head = branch.head else { return .failure(.detachedHead) }
        guard branch.upstream != nil, let remote = branch.remote, let mergeRef = branch.mergeRef else {
            return .failure(.noUpstream)
        }
        guard isPlainRefName(head) else { return .failure(.unsafeBranch) }
        guard isPlainRemoteName(remote) else { return .failure(.unsafeRemote) }
        guard mergeRef.hasPrefix("refs/heads/"), isPlainRefName(String(mergeRef.dropFirst("refs/heads/".count))) else {
            return .failure(.unsafeBranch)
        }
        return .success(["push", "--no-follow-tags", remote, "refs/heads/\(head):\(mergeRef)"])
    }

    public enum Offer: Equatable, Sendable {
        case ready(branch: String, upstream: String, ahead: Int)
        case nothingToPush
        case blocked(String)
    }

    /// What the push step should say: the push the phone could ask for, or why it cannot.
    public static func offer(for branch: AgentGitBranch?) -> Offer {
        guard let branch else { return .blocked("This folder's branch could not be read.") }
        switch arguments(for: branch) {
        case .failure(let reason): return .blocked(reason.text)
        case .success:
            guard let head = branch.head, let upstream = branch.upstream else { return .blocked(AgentGitRefusal.noUpstream.text) }
            return branch.ahead > 0 ? .ready(branch: head, upstream: upstream, ahead: branch.ahead) : .nothingToPush
        }
    }

    /// Letters, digits and `._-/` only, with none of git's reserved shapes.
    static func isPlainRefName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 200 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/")
        guard name.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return !(name.hasPrefix("-") || name.hasPrefix("/") || name.hasPrefix(".") || name.hasSuffix("/")
            || name.hasSuffix(".") || name.hasSuffix(".lock") || name.contains("..") || name.contains("//") || name.contains("/."))
    }

    /// A configured remote's name, never a URL or a path.
    static func isPlainRemoteName(_ name: String) -> Bool {
        guard isPlainRefName(name) else { return false }
        return name != "." && !name.contains("/")
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
