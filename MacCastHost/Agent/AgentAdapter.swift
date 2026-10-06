import Foundation
import RemoteCore

/// What one agent session's CLI looks like from the manager's side.
///
/// Two implementations behind it, and they are not the same shape: Claude Code is one process that
/// lives as long as the session, and Codex is one process per turn against a stored thread. What
/// the manager needs from both is only this: events out, prompts and answers in.
protocol AgentAdapter: AnyObject, Sendable {
    /// A normalised event, in the order the CLI produced it. Called on the adapter's own queue.
    var onEvent: (@Sendable (AgentStreamEvent.Payload) -> Void)? { get set }

    /// Begins the session. Throws with a sentence for the user when the CLI is missing or refuses
    /// to start.
    func start() throws

    /// Sends a user turn. One at a time: the panel does not offer a second until the first ends.
    func prompt(_ text: String)

    /// Answers an approval the CLI is waiting on. A late or unknown answer is ignored.
    func respond(approvalID: String, decision: AgentApprovalDecision)

    /// Stops the turn in flight. The session stays; the next prompt starts a new turn.
    func interrupt()

    /// Changes what the session runs. `nil` is the CLI's own default.
    ///
    /// One protocol over two different answers: Claude is told inside the running process and
    /// confirms it, Codex takes a model per turn and applies this one to its next. What the
    /// manager gets either way is ``onModel``, once the change is real.
    func setModel(_ model: String?)

    /// The model the session runs, as the CLI resolved it — not as it was asked for, since
    /// Claude answers `sonnet` with a dated full name and that is the interesting one to show.
    var onModel: (@Sendable (String?) -> Void)? { get set }

    /// Ends the session and the CLI with it.
    func stop()
}
