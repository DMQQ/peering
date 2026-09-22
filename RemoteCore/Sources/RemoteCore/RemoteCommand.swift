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
    /// Turns the picture on or off, and touches nothing else.
    ///
    /// **"Stop sending frames, keep the session" is the one thing the protocol could not say.**
    /// It is not an omission in the code but the shape of the two transports. A direct session's
    /// video has a socket of its own, and closing it does stop the Mac, but reopening it costs
    /// a fresh TLS handshake, which is most of what a client switching between Macs is trying
    /// to avoid. A relayed session has no video socket at all: the control connection *is* the
    /// video connection, so the only thing there is to close is the session itself, with its
    /// terminals, its clipboard and the assertion that keeps the Mac awake.
    ///
    /// So `false` is a pause rather than a disconnect. The session, the control channel and
    /// everything riding it stay exactly as they are, and the client keeps its shells and its
    /// place in the picture; what stops is the capture on the Mac, which is the point: a Mac
    /// nobody is looking at should not be spending its battery, its upstream, or on the relay
    /// the operator's money. `true` starts it again, and the first frame back is a keyframe,
    /// because the client's decoder has been idle and nothing else can restart it.
    ///
    /// Deliberately not a session control that ends anything, and deliberately not a
    /// ``setStreamQuality(fps:bitrateKbps:)`` of zero: a client that is looking at this Mac
    /// again must not have to re-negotiate a format, a source or a transport to see it.
    ///
    /// **A client must not send this to a Mac that has not said it understands it.** An unknown
    /// command is a decode failure in the middle of a session, so the Mac declares the
    /// capability in ``ServerHello/supportsVideoPause`` and an older one fails at the door
    /// instead.
    case setVideoEnabled(Bool)
    /// Asks the host to re-photograph the desktop being shown, ahead of the schedule it would
    /// otherwise keep to.
    ///
    /// A signal rather than a request for data: the picture arrives the way every other preview
    /// does, on the catalogue the host pushes when one lands. What this buys is *timing*. The
    /// desktops panel is the one moment a user can see how old the pictures are, and the host
    /// has no way to know it has been opened — this is the client saying so.
    case refreshSpacePreviews
    /// Asks the host to photograph each running application, for the picker's grid.
    ///
    /// **The same shape as ``refreshSpacePreviews`` and for the same reason**: the pictures
    /// arrive the way every other preview does, on the catalogue the host pushes when they land,
    /// and what this buys is *timing*. The host takes these off a schedule of its own — never, in
    /// fact, unless asked — and it cannot see that the Apps panel has just been opened, which is
    /// the only moment anybody looks at a thumbnail.
    ///
    /// **A capability rather than a version bump.** A Mac built before this command existed
    /// cannot decode it, and an unknown command is a decode failure in the middle of a session —
    /// but that Mac is never sent one, because the client asks only after
    /// ``ServerHello/supportsSourceThumbnails``. See that field for the argument; it is the one
    /// ``ServerHello/supportsMosaic`` makes.
    case refreshSourceThumbnails
    /// Dims supported physical displays to zero brightness while leaving capture running.
    /// `false` restores the levels saved when the mode was enabled.
    case setPrivacyMode(enabled: Bool)
    /// Locks the active macOS session. Unlocking remains a local action at the Mac.
    case lockScreen
    /// Asks the host to read its pasteboard and reply with a ``MessageKind/clipboardContent`` frame.
    ///
    /// The host decides what is on its pasteboard, including whether it is text or a picture, so
    /// this one command asks for both. See ``ClipboardPayload``.
    case requestClipboard
    /// Pushes text from the phone's clipboard to the host pasteboard.
    case pushClipboard(text: String)
    /// Pushes a picture from the phone's clipboard to the host pasteboard.
    ///
    /// **PNG, always**, whatever the pasteboard was holding. See ``ClipboardPayload/image``.
    ///
    /// A separate case rather than a wider ``pushClipboard(text:)``, because widening the existing
    /// one would change the shape of a command that every session with a clipboard sends, so a Mac
    /// that has not updated would fail to decode an ordinary copied line of text. This one is sent
    /// only to a Mac that has said it can take it, see
    /// ``ServerHello/supportsClipboardImages``, and a Mac that has not is a Mac whose clipboard
    /// keeps carrying text.
    ///
    /// The payload is over the control channel's limit for anything larger than a thumbnail, so it
    /// travels cut into pieces by ``ClipboardTransfer``. That is invisible from here: this is
    /// ordinary JSON and the chunking is the transport's business.
    case pushClipboardImage(png: Data)

    public var coalescing: Coalescing {
        switch self {
        case .mouseMove:
            return .replaceLatest
        case .joystickMove, .scroll:
            return .accumulate
        case .mouseDown, .mouseUp, .keyDown, .keyUp, .textInput, .switchSpace,
             .switchToSpace, .setCaptureSource, .launchApplication, .setStreamQuality,
             .setVideoEnabled, .refreshSpacePreviews, .refreshSourceThumbnails,
             .setPrivacyMode, .lockScreen, .requestClipboard, .pushClipboard,
             .pushClipboardImage:
            return .none
        }
    }

    /// Whether this command must survive a bounded send queue even when it is full.
    /// Anything whose loss would leave the host in a stuck state takes priority.
    public var isCritical: Bool {
        switch self {
        case .mouseDown, .mouseUp, .keyDown, .keyUp, .setCaptureSource, .launchApplication,
             .setPrivacyMode, .lockScreen, .pushClipboard, .pushClipboardImage, .setVideoEnabled:
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
        case .setCaptureSource, .launchApplication, .setStreamQuality, .setVideoEnabled,
             .refreshSpacePreviews, .refreshSourceThumbnails, .setPrivacyMode, .lockScreen,
             .requestClipboard, .pushClipboard, .pushClipboardImage:
            return false
        }
    }

    /// The subset of ``isUserInput`` that a mosaic on screen blocks.
    ///
    /// A mosaic blocks what carries a point or a keystroke, because it does not know which window
    /// a point landed in. Switching Space carries neither, and blocking it silently meant the
    /// picker could show a desktop and not choose it. Keys are in despite carrying no point:
    /// during a mosaic, typing goes to whichever window the Mac has focused.
    public var isBlockedByMosaic: Bool {
        switch self {
        case .mouseMove, .mouseDown, .mouseUp, .scroll, .keyDown, .keyUp, .textInput,
             .joystickMove:
            return true
        case .switchSpace, .switchToSpace, .setCaptureSource, .launchApplication,
             .setStreamQuality, .setVideoEnabled, .refreshSpacePreviews,
             .refreshSourceThumbnails, .setPrivacyMode, .lockScreen, .requestClipboard,
             .pushClipboard, .pushClipboardImage:
            return false
        }
    }
}
