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
    /// Jump directly to a 1-based Space index on one display. The host resolves it to a CGS
    /// workspace ID, so this works even if the user's Mission Control keyboard shortcuts are
    /// disabled.
    ///
    /// `display` is a `CGDirectDisplayID`'s raw value. Spaces are per-display, so an index on
    /// its own does not name a desktop: the same 1 is valid on every screen, and switching the
    /// wrong screen's first desktop is a wrong answer that looks like a right one.
    case switchToSpace(display: UInt32, index: Int)
    case joystickMove(dx: Double, dy: Double)
    /// Client-driven source switch. Applied with `SCStream.updateContentFilter(_:)`,
    /// so the stream is never torn down.
    case setCaptureSource(CaptureSource)
    /// Launches a locally installed GUI app. The host resolves the bundle identifier from
    /// its own application catalogue; clients never send executable paths.
    case launchApplication(bundleIdentifier: String)
    /// Requests a live change to the stream's quality. The host applies `bitrateKbps` to the
    /// running encoder and `fps` to the capture pipeline's frame interval. A value of 0 for
    /// either field means "keep current". Takes effect on the next keyframe.
    case setStreamQuality(fps: Int, bitrateKbps: Int)
    /// Asks the host to re-photograph the desktop being shown, ahead of the schedule it would
    /// otherwise keep to.
    ///
    /// A signal rather than a request for data: the picture arrives the way every other preview
    /// does, on the catalogue the host pushes when one lands. What this buys is *timing*. The
    /// desktops panel is the one moment a user can see how old the pictures are, and the host
    /// has no way to know it has been opened — this is the client saying so.
    case refreshSpacePreviews
    /// Dims supported physical displays to zero brightness while leaving capture running.
    /// `false` restores the levels saved when the mode was enabled.
    case setPrivacyMode(enabled: Bool)
    /// Locks the active macOS session. Unlocking remains a local action at the Mac.
    case lockScreen
    /// Asks the host to read its pasteboard and reply with a ``MessageKind/clipboardContent`` frame.
    case requestClipboard
    /// Pushes text from the phone's clipboard to the host pasteboard.
    case pushClipboard(text: String)

    public var coalescing: Coalescing {
        switch self {
        case .mouseMove:
            return .replaceLatest
        case .joystickMove, .scroll:
            return .accumulate
        case .mouseDown, .mouseUp, .keyDown, .keyUp, .textInput, .switchSpace,
             .switchToSpace, .setCaptureSource, .launchApplication, .setStreamQuality,
             .refreshSpacePreviews, .setPrivacyMode, .lockScreen,
             .requestClipboard, .pushClipboard:
            return .none
        }
    }

    /// Whether this command must survive a bounded send queue even when it is full.
    /// Anything whose loss would leave the host in a stuck state takes priority.
    public var isCritical: Bool {
        switch self {
        case .mouseDown, .mouseUp, .keyDown, .keyUp, .setCaptureSource, .launchApplication,
             .setPrivacyMode, .lockScreen, .pushClipboard:
            return true
        default:
            return false
        }
    }

    /// Commands that can change what a person or application on the Mac is doing.
    /// Stream/session controls stay available in observe mode; pointer and keyboard input do not.
    public var isUserInput: Bool {
        switch self {
        case .mouseMove, .mouseDown, .mouseUp, .scroll, .keyDown, .keyUp, .textInput,
             .switchSpace, .switchToSpace, .joystickMove:
            return true
        case .setCaptureSource, .launchApplication, .setStreamQuality, .refreshSpacePreviews,
             .setPrivacyMode, .lockScreen, .requestClipboard, .pushClipboard:
            return false
        }
    }
}
