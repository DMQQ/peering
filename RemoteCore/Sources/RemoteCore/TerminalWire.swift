import Foundation

/// A terminal owned by the Mac host. The identifier remains stable while the control client
/// disconnects, allowing a later authenticated connection to reattach to the same process.
public struct TerminalSessionInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let isRunning: Bool

    public init(id: UUID, name: String, isRunning: Bool) {
        self.id = id
        self.name = name
        self.isRunning = isRunning
    }
}

/// Requests sent by an authenticated client over the control connection.
public enum TerminalRequest: Codable, Equatable, Sendable {
    case list
    case create(name: String)
    case input(sessionID: UUID, data: Data)
    case resize(sessionID: UUID, columns: UInt16, rows: UInt16)
    case close(sessionID: UUID)
}

public enum TerminalAttentionKind: String, Codable, Equatable, Sendable {
    case confirmation
    case password
}

/// Terminal state and byte output sent by the host. Output remains bytes because a PTY may
/// split UTF-8 scalars between reads and emits ANSI control sequences by design.
public enum TerminalEvent: Codable, Equatable, Sendable {
    case snapshot([TerminalSessionInfo])
    case created(TerminalSessionInfo)
    case output(sessionID: UUID, data: Data)
    case attention(sessionID: UUID, kind: TerminalAttentionKind, message: String)
    case exited(sessionID: UUID, status: Int32)
    case closed(sessionID: UUID)
    case failed(sessionID: UUID?, message: String)
}
