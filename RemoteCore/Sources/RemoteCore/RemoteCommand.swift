import Foundation

/// Keyboard modifiers, as an `OptionSet` over the platform's own bit layout.
///
/// The raw values match `CGEventFlags` / `NSEvent.ModifierFlags`, so the host translates
/// with a bare `CGEventFlags(rawValue:)` at the injection boundary and nowhere else.
/// Verified against `NSEvent.h`: shift `1<<17`, control `1<<18`, option `1<<19`,
/// command `1<<20`.
///
/// Defined here rather than borrowed from AppKit because `NSEvent` does not exist in the
/// iOS SDK — importing it would make this module macOS-only, which is precisely the trap
/// that made the original spec's `RemoteCommand` uncompilable on the client.
public struct Modifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let shift   = Modifiers(rawValue: 1 << 17)
    public static let control = Modifiers(rawValue: 1 << 18)
    public static let option  = Modifiers(rawValue: 1 << 19)
    public static let command = Modifiers(rawValue: 1 << 20)

    public static let none: Modifiers = []
}

extension Modifiers: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UInt.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum MouseButton: UInt8, Codable, Sendable {
    case left = 0
    case right = 1
    case middle = 2
}

public enum SpaceDirection: String, Codable, Sendable {
    case left, right
}

/// How a queued command may be treated when a newer one arrives.
///
/// The distinction matters and is easy to get wrong: coalescing a *relative* command by
/// "newest wins" silently discards the earlier deltas, so a fast scroll gesture arrives
/// as a single small nudge.
public enum Coalescing: Sendable {
    /// Never drop or reorder. Press/release pairing is correctness: a dropped
    /// `mouseUp` leaves a button stuck down on the host.
    case none
    /// The value is an absolute position, so a newer sample supersedes an older one.
    case replaceLatest
    /// The value is a relative delta, so queued samples must be **summed**, not dropped.
    case accumulate
}

/// A single instruction for the host.
///
/// Coordinates are normalized `0…1` rather than pixels, which is what makes them survive
/// a zoomed client canvas and a mid-session display switch.
public enum RemoteCommand: Codable, Sendable, Equatable {
    case mouseMove(to: NormalizedPoint)
    case mouseDown(button: MouseButton)
    case mouseUp(button: MouseButton)
    /// Relative scroll deltas, in the client's units. Accumulates.
    case scroll(dx: Double, dy: Double)
    /// Keycode mode: a real hardware keycode, so shortcuts like ⌘S and ⌘Tab behave
    /// exactly as they do on a physical keyboard.
    case keyDown(keyCode: UInt16, modifiers: Modifiers)
    case keyUp(keyCode: UInt16, modifiers: Modifiers)
    /// Unicode mode: text injected via `CGEventKeyboardSetUnicodeString`. Layout-independent,
    /// so emoji and CJK work, but shortcuts that listen for physical keycodes will not fire.
    case textInput(String)
    case switchSpace(direction: SpaceDirection)
    case joystickMove(dx: Double, dy: Double)
    /// Client-driven source switch. Applied with `SCStream.updateContentFilter(_:)`,
    /// so the stream is never torn down.
    case setCaptureSource(CaptureSource)

    public var coalescing: Coalescing {
        switch self {
        case .mouseMove:
            return .replaceLatest
        case .joystickMove, .scroll:
            return .accumulate
        case .mouseDown, .mouseUp, .keyDown, .keyUp, .textInput, .switchSpace, .setCaptureSource:
            return .none
        }
    }

    /// Whether this command must survive a bounded send queue even when it is full.
    /// Anything whose loss would leave the host in a stuck state takes priority.
    public var isCritical: Bool {
        switch self {
        case .mouseDown, .mouseUp, .keyDown, .keyUp, .setCaptureSource:
            return true
        default:
            return false
        }
    }
}
