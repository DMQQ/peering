import Foundation
import RemoteCore

public struct RemoteTerminal: Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var isRunning: Bool
    public var output = Data()
    /// Set while the Mac is waiting on an answer — a password, or a yes or no.
    public var attention: TerminalAttentionKind?
    /// The last thing this terminal was asked to do that did not work, until it speaks again.
    public var failure: String?

    /// A terminal as the Mac has just described it: opened, with nothing read from it yet.
    ///
    /// The three fields the wire carries and nothing else. `output`, `attention` and `failure`
    /// arrive from later messages, which is why they are not parameters — a caller that had to
    /// pass empty ones would be spelling out a state it does not know.
    public init(id: UUID, name: String, isRunning: Bool) {
        self.id = id
        self.name = name
        self.isRunning = isRunning
    }

    /// What the tab is saying about it.
    ///
    /// One value rather than four flags read in four places, because the tab can only be one
    /// colour and the order they are weighed in is most of the design: something waiting on the
    /// user outranks something broken, which outranks a shell that has ended, which outranks one
    /// that has not said anything yet.
    public var state: TerminalState {
        if let attention { return .attention(attention) }
        if let failure { return .failed(failure) }
        if !isRunning { return .stopped }
        return output.isEmpty ? .starting : .running
    }

    public var visibleOutput: String {
        TerminalTextSanitizer.render(output)
    }
}

/// What a terminal's tab is saying about it. See ``RemoteTerminal/state``.
public enum TerminalState: Equatable {
    /// Opened, and the Mac has not answered yet — the login shell is still coming up.
    case starting
    case running
    /// Waiting on the user: a password prompt or a confirmation.
    case attention(TerminalAttentionKind)
    /// Something asked of it did not work, or its shell ended with a status.
    case failed(String)
    /// The shell has ended. Not a failure — an exit is a thing shells do.
    case stopped
}
