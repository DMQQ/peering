import Foundation

/// Raw values match `CGEventFlags` / `NSEvent.ModifierFlags` (shift 1<<17 to command 1<<20) so the host translates directly. Not borrowed from AppKit because `NSEvent` is absent from the iOS SDK.
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

public enum WindowAction: String, Codable, Sendable {
    case close, minimize, zoom
}

public enum MediaKey: Sendable, CaseIterable {
    case brightnessDown, brightnessUp, missionControl, spotlight
    case rewind, playPause, fastForward, mute, volumeDown, volumeUp

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

/// "Newest wins" on a relative command discards earlier deltas, so a fast scroll would become one small nudge.
public enum Coalescing: Sendable {
    /// Never drop or reorder. Press/release pairing is correctness: a dropped
    /// `mouseUp` leaves a button stuck down on the host.
    case none
    case replaceLatest
    case accumulate
}

/// Coordinates are normalized `0…1` so they survive a zoomed canvas and display switches.
public enum RemoteCommand: Codable, Sendable, Equatable {
    case mouseMove(to: NormalizedPoint)
    case mouseDown(button: MouseButton)
    case mouseUp(button: MouseButton)
    case scroll(dx: Double, dy: Double)
    /// Keycode mode: a real hardware keycode, so shortcuts like ⌘S and ⌘Tab behave
    /// exactly as they do on a physical keyboard.
    case keyDown(keyCode: UInt16, modifiers: Modifiers)
    case keyUp(keyCode: UInt16, modifiers: Modifiers)
    /// Unicode mode: text injected via `CGEventKeyboardSetUnicodeString`. Layout-independent,
    /// so emoji and CJK work, but shortcuts that listen for physical keycodes will not fire.
    case textInput(String)
    case switchSpace(direction: SpaceDirection)
    /// Jump to a 1-based Space index. Spaces are per display (`display` is a `CGDirectDisplayID`), so the index alone names nothing.
    case switchToSpace(display: UInt32, index: Int)
    case joystickMove(dx: Double, dy: Double)
    case setCaptureSource(CaptureSource)
    /// The host resolves the bundle identifier from its own catalogue; clients never send executable paths.
    case launchApplication(bundleIdentifier: String)
    /// Requests a live change to the stream's quality. The host applies `bitrateKbps` to the
    /// running encoder and `fps` to the capture pipeline's frame interval. A value of 0 for
    /// either field means "keep current". Takes effect on the next keyframe.
    case setStreamQuality(fps: Int, bitrateKbps: Int)
    /// Pauses (`false`) or resumes the picture; session, control channel and terminals stay. The first frame after resume is a keyframe.
    /// A client must not send this to a Mac that does not declare
    /// ``ServerHello/supportsVideoPause``: an unknown command is a decode failure mid-session.
    case setVideoEnabled(Bool)
    /// Asks the host to re-photograph the desktop shown, ahead of its schedule. A timing signal; pictures arrive on the catalogue.
    case refreshSpacePreviews
    /// Same shape as ``refreshSpacePreviews``, for the Apps panel grid. Gated by ``ServerHello/supportsSourceThumbnails``.
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
    case requestClipboard
    case pushClipboard(text: String)
    /// PNG always. Separate from ``pushClipboard(text:)`` because widening that would break decoding on an un-updated Mac; send only after ``ServerHello/supportsClipboardImages``. Large payloads are cut by ``ClipboardTransfer``.
    case pushClipboardImage(png: Data)

    /// Tells the host the phone's orientation so a virtual display can rotate. Only for a Mac declaring ``ServerHello/supportsDeviceOrientation``. A state report, so it coalesces like ``mouseMove(to:)``.
    case reportDeviceOrientation(isLandscape: Bool)

    /// Empty `name` asks the host to pick one. `width`/`height` are portrait pixels regardless of `startLandscape`, clamped by the host.
    /// Sent only to a Mac that has declared ``ServerHello/supportsVirtualDisplayManagement``.
    case addVirtualDisplay(name: String, width: Int, height: Int, startLandscape: Bool)
    /// Asks the host to remove a display it made; `displayID` is a `CGDirectDisplayID`'s raw value.
    case removeVirtualDisplay(displayID: UInt32)
    /// Renames a display, on the same terms as ``removeVirtualDisplay(displayID:)``.
    case renameVirtualDisplay(displayID: UInt32, name: String)
    case performWindowAction(windowID: UInt32, action: WindowAction)
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

    /// The subset of ``isUserInput`` a mosaic blocks: whatever carries a point or keystroke, since it cannot tell which window a point hit.
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
