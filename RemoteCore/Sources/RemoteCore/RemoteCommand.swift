import Foundation

/// Keyboard modifiers, as an `OptionSet` over the platform's own bit layout.
///
/// The raw values match `CGEventFlags` / `NSEvent.ModifierFlags`, so the host translates with a
/// bare `CGEventFlags(rawValue:)` at the injection boundary and nowhere else. Verified against
/// `NSEvent.h`: shift `1<<17`, control `1<<18`, option `1<<19`, command `1<<20`.
///
/// Defined here rather than borrowed from AppKit because `NSEvent` does not exist in the iOS SDK:
/// importing it would make this module macOS-only.
public struct Modifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let shift   = Modifiers(rawValue: 1 << 17)
    public static let control = Modifiers(rawValue: 1 << 18)
    public static let option  = Modifiers(rawValue: 1 << 19)
    public static let command = Modifiers(rawValue: 1 << 20)

    /// Asks for an F-key's printed action (``MediaKey``) instead of the key. The host passes
    /// these bits straight to `CGEventFlags`, and this one is `maskNonCoalesced`, which does
    /// nothing on a key event, so a host that predates it posts the plain F-key.
    public static let topRowAction = Modifiers(rawValue: 1 << 8)

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

/// What a window's title-bar button does: red, yellow, green.
public enum WindowAction: String, Codable, Sendable {
    case close, minimize, zoom
}

/// What a Mac keyboard's top row does without fn. F5 and F6 have none.
public enum MediaKey: Sendable, CaseIterable {
    case brightnessDown, brightnessUp, missionControl, spotlight
    case rewind, playPause, fastForward, mute, volumeDown, volumeUp

    /// The Mac's virtual key codes for F1 to F12, in order. They are not sequential.
    public static let functionKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    public init?(functionKeyCode code: UInt16) {
        let row: [MediaKey?] = [
            .brightnessDown, .brightnessUp, .missionControl, .spotlight, nil, nil,
            .rewind, .playPause, .fastForward, .mute, .volumeDown, .volumeUp,
        ]
        guard let index = Self.functionKeyCodes.firstIndex(of: code), let key = row[index] else {
            return nil
        }
        self = key
    }
}

public enum SpaceDirection: String, Codable, Sendable {
    case left, right
}

/// How a queued command may be treated when a newer one arrives.
///
/// "Newest wins" on a relative command silently discards the earlier deltas, so a fast scroll
/// gesture arrives as a single small nudge.
public enum Coalescing: Sendable {
    /// Never drop or reorder. Press/release pairing is correctness: a dropped
    /// `mouseUp` leaves a button stuck down on the host.
    case none
    /// The value is an absolute position, so a newer sample supersedes an older one.
    case replaceLatest
    /// The value is a relative delta, so queued samples must be summed, not dropped.
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
    /// `display` is a `CGDirectDisplayID`'s raw value. Spaces are per-display, so an index on its
    /// own does not name a desktop: the same 1 is valid on every screen.
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
    /// `false` is a pause rather than a disconnect: the session, the control channel, its terminals
    /// and the client's place in the picture all stay, and what stops is the capture on the Mac.
    /// `true` starts it again, and the first frame back is a keyframe, because the client's decoder
    /// has been idle. Not a ``setStreamQuality(fps:bitrateKbps:)`` of zero: a client looking at
    /// this Mac again must not have to re-negotiate to see it.
    ///
    /// A client must not send this to a Mac that does not declare
    /// ``ServerHello/supportsVideoPause``: an unknown command is a decode failure mid-session.
    case setVideoEnabled(Bool)
    /// Asks the host to re-photograph the desktop being shown, ahead of the schedule it would
    /// otherwise keep to.
    ///
    /// A signal rather than a request for data: the picture arrives on the catalogue the host
    /// pushes when one lands, and what this buys is timing, since the host cannot see that the
    /// desktops panel has been opened.
    case refreshSpacePreviews
    /// Asks the host to photograph each running application, for the picker's grid.
    ///
    /// The same shape as ``refreshSpacePreviews``: the pictures arrive on the host's catalogue, and
    /// what this buys is timing, since the host takes these off a schedule of its own and cannot
    /// see that the Apps panel has just been opened.
    ///
    /// A capability rather than a version bump: the client asks only after
    /// ``ServerHello/supportsSourceThumbnails``, so a Mac built before this command existed is
    /// never sent one.
    case refreshSourceThumbnails
    /// The picker's grid opening (`true`) or closing (`false`). While it is open the host keeps
    /// re-photographing the sources and pushes the catalogue only when a picture changed, so the
    /// tiles follow the Mac without the phone polling.
    case watchSourceThumbnails(Bool)
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
    /// PNG, always, whatever the pasteboard was holding. See ``ClipboardPayload/image``.
    ///
    /// A separate case rather than a wider ``pushClipboard(text:)``: widening that one would change
    /// the shape of a command every session with a clipboard sends, so a Mac that has not updated
    /// would fail to decode an ordinary copied line of text. Sent only to a Mac that has said it
    /// can take it, see ``ServerHello/supportsClipboardImages``. Anything larger than a thumbnail
    /// travels cut into pieces by ``ClipboardTransfer``.
    case pushClipboardImage(png: Data)

    /// Tells the host which way the phone is currently held, so a virtual display can rotate its
    /// shape to match rather than being letterboxed inside whatever the phone shows.
    ///
    /// Sent only to a Mac that has declared ``ServerHello/supportsDeviceOrientation``. A state
    /// report rather than a delta, so ``coalescing`` treats it like ``mouseMove(to:)``: only the
    /// latest one before the host gets to it is worth acting on.
    case reportDeviceOrientation(isLandscape: Bool)

    /// Asks the host to make another virtual display. Empty `name` asks the host to pick one.
    ///
    /// `width`/`height` are the display's portrait pixel size — the same convention
    /// ``VirtualDisplay``'s own `size` parameter uses, portrait regardless of `startLandscape` —
    /// and the host clamps them, so a client offering an unreasonable size costs it a smaller
    /// display rather than costing the Mac a failure.
    ///
    /// Sent only to a Mac that has declared ``ServerHello/supportsVirtualDisplayManagement``, and
    /// only by a plan that includes it: see `PlanCapability.virtualDisplays` in `MacCastKit`.
    case addVirtualDisplay(name: String, width: Int, height: Int, startLandscape: Bool)
    /// Asks the host to take a display away. `displayID` is a `CGDirectDisplayID`'s raw value, as
    /// read off a ``CaptureSourceDescriptor`` whose ``CaptureSourceDescriptor/isManagedVirtualDisplay``
    /// is `true` — this app never lets a client name a display it did not itself make.
    case removeVirtualDisplay(displayID: UInt32)
    /// Asks the host to give a display a new name, on the same terms as
    /// ``removeVirtualDisplay(displayID:)``: `displayID` must be one this host made.
    case renameVirtualDisplay(displayID: UInt32, name: String)
    /// Presses one of a window's title-bar buttons. `windowID` is a `CGWindowID`.
    case performWindowAction(windowID: UInt32, action: WindowAction)
    /// Opens another window of a running application, as ⌘N would.
    case openNewWindow(bundleIdentifier: String)

    public var coalescing: Coalescing {
        switch self {
        case .mouseMove, .reportDeviceOrientation:
            return .replaceLatest
        case .joystickMove, .scroll:
            return .accumulate
        case .mouseDown, .mouseUp, .keyDown, .keyUp, .textInput, .switchSpace,
             .switchToSpace, .setCaptureSource, .launchApplication, .setStreamQuality,
             .setVideoEnabled, .refreshSpacePreviews, .refreshSourceThumbnails,
             .watchSourceThumbnails, .setPrivacyMode, .lockScreen, .requestClipboard, .pushClipboard,
             .pushClipboardImage, .addVirtualDisplay, .removeVirtualDisplay,
             .renameVirtualDisplay, .performWindowAction, .openNewWindow:
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
             .refreshSpacePreviews, .refreshSourceThumbnails, .watchSourceThumbnails,
             .setPrivacyMode, .lockScreen, .requestClipboard, .pushClipboard, .pushClipboardImage, .reportDeviceOrientation,
             .addVirtualDisplay, .removeVirtualDisplay, .renameVirtualDisplay,
             .performWindowAction, .openNewWindow:
            return false
        }
    }

    /// The subset of ``isUserInput`` that a mosaic on screen blocks.
    ///
    /// A mosaic blocks what carries a point or a keystroke, because it does not know which window a
    /// point landed in; switching Space carries neither. Keys are in despite carrying no point:
    /// during a mosaic, typing goes to whichever window the Mac has focused.
    public var isBlockedByMosaic: Bool {
        switch self {
        case .mouseMove, .mouseDown, .mouseUp, .scroll, .keyDown, .keyUp, .textInput,
             .joystickMove:
            return true
        case .switchSpace, .switchToSpace, .setCaptureSource, .launchApplication,
             .setStreamQuality, .setVideoEnabled, .refreshSpacePreviews,
             .refreshSourceThumbnails, .watchSourceThumbnails, .setPrivacyMode, .lockScreen,
             .requestClipboard, .pushClipboard, .pushClipboardImage, .reportDeviceOrientation,
             .addVirtualDisplay, .removeVirtualDisplay, .renameVirtualDisplay,
             .performWindowAction, .openNewWindow:
            return false
        }
    }
}
