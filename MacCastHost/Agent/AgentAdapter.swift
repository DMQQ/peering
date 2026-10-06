import Foundation
import RemoteCore

protocol AgentAdapter: AnyObject, Sendable {
    var onEvent: (@Sendable (AgentStreamEvent.Payload) -> Void)? { get set }

    func start() throws

    func prompt(_ text: String)

    /// Answers an approval the CLI is waiting on. A late or unknown answer is ignored.
    func respond(approvalID: String, decision: AgentApprovalDecision)

    func interrupt()

    /// Changes what the session runs. `nil` is the CLI's own default.
    func setModel(_ model: String?)

    /// The model as the CLI resolved it, not as asked: Claude answers `sonnet` with a dated full name.
    var onModel: (@Sendable (String?) -> Void)? { get set }

    /// The modes this CLI can really be put in, safest first. Never padded to three: a mode it
    /// cannot honour is a toggle that lies.
    var permissionModes: [AgentPermissionMode] { get }

    /// What a new session runs in, which is what the CLI does with no flag.
    var defaultPermissionMode: AgentPermissionMode { get }

    /// Reported through ``onPermissionMode`` once the CLI has taken it; for the per-turn CLIs that
    /// is from the next turn.
    func setPermissionMode(_ mode: AgentPermissionMode)

    var onPermissionMode: (@Sendable (AgentPermissionMode) -> Void)? { get set }

    func stop()
}
