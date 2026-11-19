import Foundation

/// The independent streams that carry the frame protocol while both ends use them. A loss stalls only the stream it fell in.
public enum StreamID: UInt8, CaseIterable, Sendable {
    /// Commands and what the host reports back. Input is here on purpose: a click must not overtake the source or space change before it.
    case interactive = 1
    /// Ping and pong, so the latency shown is not another stream's repair.
    case pulse = 2
    case terminal = 3
    case agent = 4
    /// Listings, transfers and file operations: the bulk traffic, sent last.
    case files = 5

    /// Lower is sent first when the lane's shared budget runs short.
    public var priority: Int {
        switch self {
        case .interactive: return 0
        case .pulse: return 1
        case .terminal: return 2
        case .agent: return 3
        case .files: return 4
        }
    }
}
