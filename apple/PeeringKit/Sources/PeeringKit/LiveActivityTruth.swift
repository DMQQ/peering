import Foundation
import RemoteCore

/// How a session is carried, as the card words it.
public enum LiveActivityPath: String, Sendable, Equatable {
    case lan
    case relay
    case direct
}

/// One agent chat as a pushed card may describe it: a state and a glyph, never a title or a reply.
public struct LiveActivityChat: Sendable, Equatable {
    public enum State: Int, Sendable, Equatable {
        case needsYou
        case working
        case failed
        case finished
    }

    public var id: String
    public var symbol: String
    public var state: State

    public init(id: String, symbol: String, state: State) {
        self.id = id
        self.symbol = symbol
        self.state = state
    }
}

/// Everything the Mac knows that a Live Activity shows, with no free text in it.
public struct LiveActivityTruth: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case active
        /// The connection went without anyone ending it: the card offers to reconnect.
        case dropped
        /// The session was ended from this side, or this Mac stopped hosting.
        case ended
    }

    public var phase: Phase
    public var startedAt: Date?
    public var path: LiveActivityPath
    public var chats: [LiveActivityChat]

    public init(phase: Phase, startedAt: Date?, path: LiveActivityPath, chats: [LiveActivityChat]) {
        self.phase = phase
        self.startedAt = startedAt
        self.path = path
        self.chats = chats
    }

    /// The chat a card is about: the one waiting on the person, then the busy ones, then the latest to stop. Among equals the first listed wins, so the caller lists the newest first.
    public var topChat: LiveActivityChat? {
        chats.reduce(nil) { best, chat in
            guard let best else { return chat }
            return chat.state.rawValue < best.state.rawValue ? chat : best
        }
    }

    public var waitingCount: Int { chats.filter { $0.state == .needsYou }.count }
    public var workingCount: Int { chats.filter { $0.state == .working }.count }
}

/// One push the Mac should hand the relay.
public struct LiveActivityCommand: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case start
        case update
        case end
    }

    /// Why the person's attention is wanted. A fixed sentence on the phone's side, never a name.
    public enum Alert: Sendable, Equatable {
        case needsApproval
        case finished
        case failed
    }

    public var kind: LiveActivityKind
    public var event: Event
    public var token: String
    public var environment: PushEnvironment
    public var truth: LiveActivityTruth
    /// 10 when the person is needed, otherwise the relay's default for the event.
    public var priority: Int?
    public var alert: Alert?
    /// `end` only: how long the card stays on the Lock Screen. Nil leaves it to the relay's default.
    public var dismissalSeconds: UInt32? = nil
}
