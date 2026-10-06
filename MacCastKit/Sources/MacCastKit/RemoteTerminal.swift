import Foundation
import RemoteCore

public struct RemoteTerminal: Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var isRunning: Bool
    public var output = Data()
    /// Set while the Mac is waiting on an answer: a password, or a yes or no.
    public var attention: TerminalAttentionKind?
    /// The last thing this terminal was asked to do that did not work, until it speaks again.
    public var failure: String?
    /// When the Mac opened this shell, when it says. The hub reads "running for 12m" off it.
    public var createdAt: Date?

    /// The shape this shell's screen is, which is also the shape it has been told it is. Held here
    /// rather than in the panel that measures it, which is rebuilt on every open.
    public var columns = 80
    public var rows = 24

    /// The screen this terminal's output is drawn on, kept rather than rebuilt: replaying a
    /// session's bytes is only correct at one shape. See ``TerminalScreenFeed``.
    public let screenFeed = TerminalScreenFeed()

    /// The screen as it stands, having applied whatever has arrived since it was last read.
    public var screen: TerminalScreen {
        screenFeed.screen(for: output, columns: columns, rows: rows)
    }

    /// Equality is about what the Mac said, not the drawing of it: two terminals describing the
    /// same shell are equal however much of its output has been rendered.
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
    /// The three fields the wire carries and nothing else: `output`, `attention` and `failure`
    /// arrive from later messages.
    public init(id: UUID, name: String, isRunning: Bool) {
        self.id = id
        self.name = name
        self.isRunning = isRunning
    }

    /// A terminal as the Mac describes it, on the shape its screen has when the Mac says.
    public init(_ info: TerminalSessionInfo) {
        self.init(id: info.id, name: info.name, isRunning: info.isRunning)
        createdAt = info.createdAt
        if let columns = info.columns, let rows = info.rows {
            self.columns = columns
            self.rows = rows
        }
    }

    /// The terminals a listing describes: fresh screens, and the shape each of them already is.
    ///
    /// **A listing is about the Mac's sessions and nothing about their screens**, and the history
    /// that follows it is what rebuilds them. Those bytes were drawn for one grid, so a terminal
    /// rebuilt here has to be told which: the shape this phone last gave the shell, or the one the
    /// Mac repeats in the info when it can say. Left at the 80×24 default, every frame of a
    /// full-screen program is laid out wrapped and clipped, and the resize that arrives afterwards
    /// only truncates and pads, so the picture never comes back. See ``TerminalScreenFeed``.
    public static func from(
        _ infos: [TerminalSessionInfo],
        remembering previous: [RemoteTerminal]
    ) -> [RemoteTerminal] {
        infos.map { info in
            var terminal = RemoteTerminal(info)
            if info.columns == nil || info.rows == nil,
               let known = previous.first { $0.id == info.id } {
                terminal.columns = known.columns
                terminal.rows = known.rows
            }
            return terminal
        }
    }

    /// What the tab is saying about it. One value rather than four flags, because the order they
    /// are weighed in is the design: something waiting on the user outranks something broken, which
    /// outranks an ended shell, which outranks one that has not said anything yet.
    public var state: TerminalState {
        if let attention { return .attention(attention) }
        if let failure { return .failed(failure) }
        if !isRunning { return .stopped }
        return output.isEmpty ? .starting : .running
    }
}

/// What a terminal's tab is saying about it. See ``RemoteTerminal/state``.
public enum TerminalState: Equatable {
    /// Opened, and the Mac has not answered yet: the login shell is still coming up.
    case starting
    case running
    /// Waiting on the user: a password prompt or a confirmation.
    case attention(TerminalAttentionKind)
    /// Something asked of it did not work, or its shell ended with a status.
    case failed(String)
    /// The shell has ended. Not a failure: an exit is a thing shells do.
    case stopped
}
