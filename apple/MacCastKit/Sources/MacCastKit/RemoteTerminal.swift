import Foundation
import RemoteCore

public struct RemoteTerminal: Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var isRunning: Bool
    public var output = Data()
    public var attention: TerminalAttentionKind?
    public var failure: String?
    public var createdAt: Date?

    /// Held here because the measuring panel is rebuilt on every open.
    public var columns = 80
    public var rows = 24

    /// Kept rather than rebuilt: replaying a session's bytes is only correct at one shape. See ``TerminalScreenFeed``.
    public let screenFeed = TerminalScreenFeed()

    public var screen: TerminalScreen {
        screenFeed.screen(for: output, columns: columns, rows: rows)
    }

    /// Keeps the newest `limit` bytes. The feed is told how much went, as every trim must (see ``TerminalScreenFeed``).
    public mutating func trimOutput(keeping limit: Int) {
        guard output.count > limit else { return }
        let dropped = output.count - limit
        output = Data(output.dropFirst(dropped))
        screenFeed.discardFront(dropped)
    }

    public static func == (left: Self, right: Self) -> Bool {
        left.id == right.id
            && left.name == right.name
            && left.isRunning == right.isRunning
            && left.output == right.output
            && left.attention == right.attention
            && left.failure == right.failure
    }

    public init(id: UUID, name: String, isRunning: Bool) {
        self.id = id
        self.name = name
        self.isRunning = isRunning
    }

    public init(_ info: TerminalSessionInfo) {
        self.init(id: info.id, name: info.name, isRunning: info.isRunning)
        createdAt = info.createdAt
        if let columns = info.columns, let rows = info.rows {
            self.columns = columns
            self.rows = rows
        }
    }

    /// A listing says nothing about screens; the history that follows rebuilds them, and those bytes were drawn for one grid. Left at 80×24, full-screen programs wrap and clip and a later resize only truncates and pads, so the picture never recovers. See ``TerminalScreenFeed``.
    public static func from(
        _ infos: [TerminalSessionInfo],
        remembering previous: [RemoteTerminal]
    ) -> [RemoteTerminal] {
        infos.map { info in
            var terminal = RemoteTerminal(info)
            if info.columns == nil || info.rows == nil,
               let known = previous.first(where: { $0.id == info.id }) {
                terminal.columns = known.columns
                terminal.rows = known.rows
            }
            return terminal
        }
    }

    /// One value rather than four flags: waiting on the user outranks broken, which outranks ended, which outranks not yet heard from.
    public var state: TerminalState {
        if let attention { return .attention(attention) }
        if let failure { return .failed(failure) }
        if !isRunning { return .stopped }
        return output.isEmpty ? .starting : .running
    }
}

public enum TerminalState: Equatable {
    case starting
    case running
    case attention(TerminalAttentionKind)
    case failed(String)
    case stopped
}
