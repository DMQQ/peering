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

    /// The shape this shell's screen is, which is also the shape it has been told it is.
    ///
    /// Here rather than in the panel that measures it, because the panel is rebuilt every time it
    /// is opened and this is not: a shell is still the size it was when the panel that sized it was
    /// closed. It is what ``screen`` is drawn against, so the two cannot disagree about it.
    public var columns = 80
    public var rows = 24

    /// The screen this terminal's output is drawn on, kept rather than rebuilt.
    ///
    /// A rendering cache with the life of the shell rather than of a view: replaying a session's
    /// bytes is only correct at one shape, so it may only happen once, when there is nothing to
    /// replay. See ``TerminalScreenFeed``.
    public let screenFeed = TerminalScreenFeed()

    /// The screen as it stands, having applied whatever has arrived since it was last read.
    public var screen: TerminalScreen {
        screenFeed.screen(for: output, columns: columns, rows: rows)
    }

    /// Equality is about what the Mac said, and the screen is a drawing of it: two terminals that
    /// describe the same shell are equal however much of its output has been rendered.
    public static func == (left: Self, right: Self) -> Bool {
        left.id == right.id
            && left.name == right.name
            && left.isRunning == right.isRunning
            && left.output == right.output
            && left.attention == right.attention
            && left.failure == right.failure
    }

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
