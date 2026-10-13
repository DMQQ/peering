import Foundation

/// Where a session's folder stands on its branch, as git's status header reports it.
public struct AgentGitBranch: Codable, Equatable, Sendable {
    /// The checked-out branch; nil on a detached HEAD.
    public let head: String?
    /// The branch it follows, as git prints it (`origin/main`); nil when none is set.
    public let upstream: String?
    /// The remote's name from the branch's own configuration; nil when none is set.
    public let remote: String?
    /// The ref on that remote the branch follows (`refs/heads/main`); nil when none is set.
    public let mergeRef: String?
    public let ahead: Int
    public let behind: Int

    public init(head: String?, upstream: String?, remote: String?, mergeRef: String?, ahead: Int, behind: Int) {
        self.head = head
        self.upstream = upstream
        self.remote = remote
        self.mergeRef = mergeRef
        self.ahead = ahead
        self.behind = behind
    }
}

public enum AgentGitOperation: String, Codable, Equatable, Sendable {
    case commit, push
}

/// How a commit or a push ended, with git's own words (bounded) where it had any.
public struct AgentGitResult: Codable, Equatable, Sendable {
    public let operation: AgentGitOperation
    public let succeeded: Bool
    public let message: String

    public init(operation: AgentGitOperation, succeeded: Bool, message: String) {
        self.operation = operation
        self.succeeded = succeeded
        self.message = message
    }
}
