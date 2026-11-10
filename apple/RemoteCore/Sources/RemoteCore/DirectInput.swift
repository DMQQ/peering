import Foundation

/// A pointer command sent on the datagram path straight to the Mac. The sequence lets the Mac drop one that arrives after a newer one.
public struct DirectCommand: Codable, Sendable, Equatable {
    public let sequence: UInt32
    public let command: RemoteCommand

    public init(sequence: UInt32, command: RemoteCommand) {
        self.sequence = sequence
        self.command = command
    }

    /// Pointer movement and scrolling: a later one supersedes it and a loss is survivable, so it goes on one path only.
    public static func isMovement(_ command: RemoteCommand) -> Bool {
        switch command {
        case .mouseMove, .joystickMove, .scroll: return true
        default: return false
        }
    }

    /// Clicks and keys: a loss leaves a button or key stuck or a click missing, so they go on both paths and the Mac applies whichever copy arrives first.
    public static func isDuplicated(_ command: RemoteCommand) -> Bool {
        switch command {
        case .mouseDown, .mouseUp, .keyDown, .keyUp: return true
        default: return false
        }
    }

    public static func isEligible(_ command: RemoteCommand) -> Bool {
        isMovement(command) || isDuplicated(command)
    }
}

/// Decides, per command, whether input takes the direct path or the control connection.
///
/// A move sent direct overtakes whatever is still travelling through the relay, so after any command that must stay in order and goes only by the relay, moves stay on the control connection until the relay has had time to deliver it.
public struct DirectInputRoute: Sendable, Equatable {
    public static let quietPeriod: TimeInterval = 0.6

    public enum Path: Sendable, Equatable {
        case direct
        case control
        /// Both, for a command that must not be lost: see ``DirectCommand/isDuplicated(_:)``.
        case both
    }

    private var lastOrderedAt: TimeInterval?

    public init() {}

    public mutating func route(
        _ command: RemoteCommand,
        now: TimeInterval,
        directIsOpen: Bool,
        hostAccepts: Bool
    ) -> Path {
        guard DirectCommand.isEligible(command) else {
            lastOrderedAt = now
            return .control
        }
        if DirectCommand.isDuplicated(command) {
            guard hostAccepts, directIsOpen else {
                lastOrderedAt = now
                return .control
            }
            return .both
        }
        guard hostAccepts, directIsOpen else { return .control }
        if let lastOrderedAt, now - lastOrderedAt < Self.quietPeriod { return .control }
        return .direct
    }
}

/// The Mac's side: remembers the newest sequence and refuses anything at or before it, wrap-around included.
public struct DirectInputOrder: Sendable, Equatable {
    private var newest: UInt32?

    public init() {}

    public mutating func accepts(_ sequence: UInt32) -> Bool {
        guard let newest else {
            self.newest = sequence
            return true
        }
        // Serial-number arithmetic: a sequence is newer when it is within half the range ahead.
        guard sequence != newest, sequence &- newest < UInt32.max / 2 else { return false }
        self.newest = sequence
        return true
    }
}

/// The Mac's side of ``DirectInputRoute/Path/both``: each click or key arrives once on each path, and the first to arrive is applied.
///
/// A copy is dropped when the other path already delivered an equal one. A copy whose twin was lost waits for it until it expires, and a later equal command from the other path then takes its place, so the number applied stays the number sent.
public struct DuplicateInputFilter: Sendable {
    public enum Source: Sendable, Equatable {
        case control
        case direct
    }

    private struct Entry: Sendable {
        let source: Source
        let command: RemoteCommand
        let at: TimeInterval
    }

    public static let lifetime: TimeInterval = 10
    private static let capacity = 64

    private var entries: [Entry] = []

    public init() {}

    public mutating func shouldApply(_ command: RemoteCommand, from source: Source, now: TimeInterval) -> Bool {
        guard DirectCommand.isDuplicated(command) else { return true }
        entries.removeAll { now - $0.at > Self.lifetime }
        if let twin = entries.firstIndex(where: { $0.source != source && $0.command == command }) {
            entries.remove(at: twin)
            return false
        }
        entries.append(Entry(source: source, command: command, at: now))
        if entries.count > Self.capacity { entries.removeFirst() }
        return true
    }
}
