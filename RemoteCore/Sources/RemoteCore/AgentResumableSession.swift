import Foundation

/// A conversation a coding agent's CLI keeps on the Mac, started there rather than from this app, that a chat can pick up.
public struct AgentResumableSession: Codable, Equatable, Sendable, Identifiable {
    public let agentID: String
    /// The id the CLI resumes with.
    public let cliSessionID: String
    public let directory: String
    public let title: String
    public let modifiedAt: Date
    /// Written to a moment ago, so a terminal on the Mac may still have it open. Continuing it from here would put two writers on one conversation.
    public let mayBeOpenElsewhere: Bool

    public var id: String { "\(agentID):\(cliSessionID)" }

    public init(
        agentID: String,
        cliSessionID: String,
        directory: String,
        title: String,
        modifiedAt: Date,
        mayBeOpenElsewhere: Bool
    ) {
        self.agentID = agentID
        self.cliSessionID = cliSessionID
        self.directory = directory
        self.title = title
        self.modifiedAt = modifiedAt
        self.mayBeOpenElsewhere = mayBeOpenElsewhere
    }
}
