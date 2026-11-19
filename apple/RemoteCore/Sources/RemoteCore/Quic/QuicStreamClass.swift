import Foundation

/// The QUIC streams a session carries, one per kind of traffic so a loss or a large transfer in one never delays another. Each direction opens its own unidirectional streams, so neither end waits for the other to open one.
public enum QuicStreamClass: Int, CaseIterable, Sendable {
    case control
    case pulse
    case terminal
    case agent
    case files

    /// RFC 9218 urgency: lower goes first.
    var urgency: UInt8 {
        switch self {
        case .control: 0
        case .pulse: 1
        case .terminal: 3
        case .agent: 4
        case .files: 6
        }
    }

    /// A transfer shares its turn with others of its urgency instead of finishing first.
    var isIncremental: Bool { self == .files }

    /// Client-initiated unidirectional ids are 2, 6, 10…; server-initiated 3, 7, 11….
    func streamID(sentByClient: Bool) -> UInt64 {
        UInt64(rawValue) * 4 + (sentByClient ? 2 : 3)
    }

    init?(streamID: UInt64) {
        guard streamID % 4 >= 2 else { return nil }
        self.init(rawValue: Int(streamID / 4))
    }

    /// Where a frame goes: a stream, or nil for the kinds that travel as datagrams (picture, sound, direct pointer input), which are never retransmitted.
    static func of(_ frame: Frame) -> QuicStreamClass? {
        switch frame.kind {
        case .videoFrame, .videoChunk, .audioFrame, .directCommand:
            return nil
        case .ping, .pong:
            return .pulse
        case .terminalRequest, .terminalEvent:
            return StreamRouting.isFileWork(frame.payload) ? .files : .terminal
        case .agentRequest, .agentEvent, .previewRequest, .previewEvent:
            return .agent
        default:
            return .control
        }
    }
}
